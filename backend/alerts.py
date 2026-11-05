"""
Alertas de precio.

El usuario define un producto, un precio objetivo y cuántas veces al día
revisar. Un temporizador interno (APScheduler) revisa las alertas que ya
"tocan", busca el producto en las 4 tiendas y, si el mejor precio llega al
objetivo o menos, avisa por Telegram.

Diseñado para que más adelante haya varios usuarios: cada alerta guarda el
`user_id` de quien la creó, y la vinculación con Telegram es por usuario.
Por ahora el `user_id` es un identificador anónimo que genera la app (header
X-User-Id); cuando existan cuentas reales se reemplaza por el login.

Base de datos: DATABASE_URL (Postgres en Railway). Si no está definida se usa
un archivo SQLite local, útil para probar en el computador. OJO: en Railway
el disco no es persistente, por eso allá hay que usar Postgres.
"""

import asyncio
import os
import re
import secrets
import uuid
from datetime import datetime, timedelta, timezone
from typing import Awaitable, Callable, Optional
from zoneinfo import ZoneInfo

import requests
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from fastapi import APIRouter, Depends, Header, HTTPException
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import Boolean, DateTime, Float, Integer, String, create_engine, select
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, sessionmaker

# ---------------------------------------------------------------------------
# Base de datos
# ---------------------------------------------------------------------------

MAX_ALERTS_PER_USER = 10  # tope para controlar el gasto en Apify


def _database_url() -> str:
    url = os.getenv("DATABASE_URL") or "sqlite:///alerts.db"
    # Railway entrega "postgresql://..."; SQLAlchemy necesita indicar el driver.
    if url.startswith("postgres://"):
        url = "postgresql://" + url[len("postgres://"):]
    if url.startswith("postgresql://"):
        url = "postgresql+psycopg://" + url[len("postgresql://"):]
    return url


_url = _database_url()
engine = create_engine(
    _url,
    pool_pre_ping=True,
    connect_args={"check_same_thread": False} if _url.startswith("sqlite") else {},
)
SessionLocal = sessionmaker(engine, expire_on_commit=False)


class Base(DeclarativeBase):
    pass


def _now() -> datetime:
    """Hora UTC sin zona horaria (así se comporta igual en SQLite y Postgres)."""
    return datetime.now(timezone.utc).replace(tzinfo=None)


class Alert(Base):
    __tablename__ = "alerts"

    id: Mapped[str] = mapped_column(String(32), primary_key=True)
    user_id: Mapped[str] = mapped_column(String(64), index=True)
    query: Mapped[str] = mapped_column(String(200))
    target_price: Mapped[int] = mapped_column(Integer)
    # Días de la semana (0=lunes ... 6=domingo) y horas del día (0-23, hora de
    # Chile) en que se revisa, guardados como texto "0,1,2" / "9,18".
    days: Mapped[str] = mapped_column(String(20))
    hours: Mapped[str] = mapped_column(String(80))
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=_now)
    next_check_at: Mapped[datetime] = mapped_column(DateTime, default=_now, index=True)
    last_checked_at: Mapped[Optional[datetime]] = mapped_column(DateTime, nullable=True)
    last_best_price: Mapped[Optional[float]] = mapped_column(Float, nullable=True)
    last_best_store: Mapped[Optional[str]] = mapped_column(String(32), nullable=True)
    last_best_url: Mapped[Optional[str]] = mapped_column(String(1000), nullable=True)
    last_error: Mapped[Optional[str]] = mapped_column(String(500), nullable=True)
    # True si ya avisamos que el precio llegó al objetivo (evita avisar en cada
    # revisión). Se reactiva cuando el precio vuelve a subir sobre el objetivo.
    notified: Mapped[bool] = mapped_column(Boolean, default=False)


class UserSettings(Base):
    __tablename__ = "user_settings"

    user_id: Mapped[str] = mapped_column(String(64), primary_key=True)
    telegram_chat_id: Mapped[Optional[str]] = mapped_column(String(32), nullable=True)
    link_code: Mapped[Optional[str]] = mapped_column(String(32), nullable=True)


def init_db() -> None:
    Base.metadata.create_all(engine)


# ---------------------------------------------------------------------------
# Horario de revisión
# ---------------------------------------------------------------------------

TZ = ZoneInfo("America/Santiago")  # las 4 tiendas son chilenas
MAX_HOURS_PER_DAY = 12  # tope para controlar el gasto en Apify


def _csv_to_ints(value: str) -> list:
    return [int(x) for x in value.split(",") if x != ""]


def _next_slot(days: list, hours: list, after: Optional[datetime] = None) -> datetime:
    """Próximo momento (UTC naive) posterior a `after` que cae en uno de los
    días y horas elegidos, interpretados en hora de Chile."""
    after = after or _now()
    local = after.replace(tzinfo=timezone.utc).astimezone(TZ)
    for offset in range(0, 9):
        day = (local + timedelta(days=offset)).date()
        for hour in sorted(hours):
            cand = datetime(day.year, day.month, day.day, hour, 0, tzinfo=TZ)
            if cand > local and cand.weekday() in days:
                return cand.astimezone(timezone.utc).replace(tzinfo=None)
    return after + timedelta(days=1)  # no debería ocurrir (days/hours nunca vacíos)


# ---------------------------------------------------------------------------
# Telegram
# ---------------------------------------------------------------------------

class TelegramError(Exception):
    def __init__(self, message: str, status: int = 502):
        super().__init__(message)
        self.status = status


def _tg_call(method: str, **params) -> dict:
    """Llama a la API de Telegram. Nunca dejamos que el token aparezca en un
    mensaje de error o en los logs (la URL lo incluye)."""
    token = os.getenv("TELEGRAM_BOT_TOKEN")
    if not token:
        raise TelegramError("Falta configurar TELEGRAM_BOT_TOKEN en el backend", 503)
    try:
        resp = requests.post(
            f"https://api.telegram.org/bot{token}/{method}", json=params, timeout=15
        )
        data = resp.json()
    except Exception as exc:  # noqa: BLE001
        raise TelegramError(f"No se pudo contactar a Telegram ({type(exc).__name__})") from None
    if not data.get("ok"):
        raise TelegramError(f"Telegram rechazó la solicitud: {data.get('description')}")
    return data["result"]


def _notify(user_id: str, text: str) -> None:
    with SessionLocal() as s:
        settings = s.get(UserSettings, user_id)
        chat_id = settings.telegram_chat_id if settings else None
    if not chat_id:
        raise TelegramError("Telegram no está vinculado para este usuario", 409)
    _tg_call("sendMessage", chat_id=chat_id, text=text, disable_web_page_preview=False)


# ---------------------------------------------------------------------------
# Revisión de precios
# ---------------------------------------------------------------------------

STORE_LABELS = {
    "falabella": "Falabella",
    "ripley": "Ripley",
    "paris": "Paris",
    "ahumada": "Ahumada",
}

# Función que busca un producto en todas las tiendas. La define main.py (para
# reutilizar los actores de Apify) y se registra con `configure`.
_search_all: Optional[Callable[[str], Awaitable[list]]] = None
_check_lock = asyncio.Lock()  # una revisión a la vez: cuida el gasto en Apify


def configure(search_all: Callable[[str], Awaitable[list]]) -> None:
    global _search_all
    _search_all = search_all


def _parse_price(value) -> Optional[float]:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value) if value > 0 else None
    if isinstance(value, str):
        digits = re.sub(r"[^0-9]", "", value)
        if digits:
            return float(digits)
    return None


def _fmt_price(value: float) -> str:
    return "$" + f"{int(round(value)):,}".replace(",", ".")


def _first_value(item: dict, keys: list):
    for key in keys:
        value = item.get(key)
        if value is not None and str(value).strip():
            return value
    return None


def _pick_best(stores: list) -> Optional[dict]:
    """De cada tienda toma el primer resultado (el más parecido a lo buscado,
    ya ordenado por relevancia) y se queda con el más barato de todos. Usa las
    mismas llaves que la app para leer el precio, porque cada actor de Apify
    nombra los campos distinto."""
    best = None
    for store in stores:
        results = store.get("results") or []
        if not results:
            continue
        item = results[0]
        price = _parse_price(
            _first_value(item, ["price", "salePrice", "currentPrice", "precio", "formattedPrice"])
        )
        if price is None:
            continue
        if best is None or price < best["price"]:
            best = {
                "price": price,
                "store": store.get("store"),
                "url": _first_value(item, ["url", "link", "productUrl", "product_url"]),
            }
    return best


async def check_alert(alert_id: str) -> Optional[dict]:
    if _search_all is None:
        raise RuntimeError("alerts.configure() no fue llamado")

    async with _check_lock:
        # Programamos la próxima revisión ANTES de buscar: si algo se cae a la
        # mitad, no queda la alerta "vencida" reintentándose sin parar (y
        # gastando créditos de Apify).
        with SessionLocal() as s:
            alert = s.get(Alert, alert_id)
            if alert is None:
                return None
            query, target, user_id = alert.query, alert.target_price, alert.user_id
            alert.last_checked_at = _now()
            alert.next_check_at = _next_slot(_csv_to_ints(alert.days), _csv_to_ints(alert.hours))
            s.commit()

        best, error = None, None
        try:
            stores = await _search_all(query)
            best = _pick_best(stores)
            if best is None:
                error = "No se encontró el producto con precio en ninguna tienda"
        except Exception as exc:  # noqa: BLE001
            error = f"{type(exc).__name__}: {exc}"[:500]
            print(f"[alerts] error revisando {alert_id}: {error}", flush=True)

        should_notify = False
        with SessionLocal() as s:
            alert = s.get(Alert, alert_id)
            if alert is None:
                return None
            alert.last_error = error
            if best:
                alert.last_best_price = best["price"]
                alert.last_best_store = best["store"]
                alert.last_best_url = (best["url"] or "")[:1000] or None
                if best["price"] <= target:
                    should_notify = not alert.notified
                else:
                    alert.notified = False
            s.commit()

        if should_notify:
            label = STORE_LABELS.get(best["store"], best["store"])
            text = (
                f"Alerta de precio: {query}\n"
                f"{label} lo tiene a {_fmt_price(best['price'])} "
                f"(tu objetivo: {_fmt_price(target)}).\n"
                f"{best['url'] or ''}"
            ).strip()
            notify_error = None
            try:
                await asyncio.to_thread(_notify, user_id, text)
            except Exception as exc:  # noqa: BLE001
                notify_error = f"No se pudo enviar el aviso: {exc}"[:500]
                print(f"[alerts] {alert_id}: {notify_error}", flush=True)
            with SessionLocal() as s:
                alert = s.get(Alert, alert_id)
                if alert is not None:
                    if notify_error is None:
                        alert.notified = True
                    else:
                        alert.last_error = notify_error  # se reintenta en la próxima revisión
                    s.commit()

        with SessionLocal() as s:
            alert = s.get(Alert, alert_id)
            return _alert_dict(alert) if alert else None


async def _tick() -> None:
    """Corre cada minuto: revisa las alertas activas que ya les toca."""
    with SessionLocal() as s:
        due = list(
            s.scalars(
                select(Alert.id).where(Alert.active.is_(True), Alert.next_check_at <= _now())
            )
        )
    for alert_id in due:
        try:
            await check_alert(alert_id)
        except Exception as exc:  # noqa: BLE001
            print(f"[alerts] fallo inesperado en {alert_id}: {exc!r}", flush=True)


scheduler = AsyncIOScheduler()


def start_scheduler() -> None:
    scheduler.add_job(_tick, "interval", minutes=1, id="alerts-tick", max_instances=1, coalesce=True)
    scheduler.start()


def stop_scheduler() -> None:
    if scheduler.running:
        scheduler.shutdown(wait=False)


# ---------------------------------------------------------------------------
# API
# ---------------------------------------------------------------------------

router = APIRouter()


def _user_id(x_user_id: str = Header(...)) -> str:
    uid = x_user_id.strip()
    if not re.fullmatch(r"[A-Za-z0-9_-]{8,64}", uid):
        raise HTTPException(400, "X-User-Id inválido")
    return uid


def _iso(value: Optional[datetime]) -> Optional[str]:
    return value.isoformat() + "Z" if value else None


def _alert_dict(a: Alert) -> dict:
    return {
        "id": a.id,
        "query": a.query,
        "target_price": a.target_price,
        "days": _csv_to_ints(a.days),
        "hours": _csv_to_ints(a.hours),
        "active": a.active,
        "created_at": _iso(a.created_at),
        "next_check_at": _iso(a.next_check_at),
        "last_checked_at": _iso(a.last_checked_at),
        "last_best_price": a.last_best_price,
        "last_best_store": a.last_best_store,
        "last_best_url": a.last_best_url,
        "last_error": a.last_error,
        "notified": a.notified,
    }


def _clean_ints(values, lo: int, hi: int, name: str) -> list:
    out = sorted(set(values))
    if not out:
        raise ValueError(f"Elige al menos un valor en {name}")
    if out[0] < lo or out[-1] > hi:
        raise ValueError(f"{name} fuera de rango ({lo}-{hi})")
    return out


class _ScheduleMixin(BaseModel):
    @field_validator("days", check_fields=False)
    @classmethod
    def _v_days(cls, v):
        return None if v is None else _clean_ints(v, 0, 6, "días")

    @field_validator("hours", check_fields=False)
    @classmethod
    def _v_hours(cls, v):
        if v is None:
            return None
        out = _clean_ints(v, 0, 23, "horas")
        if len(out) > MAX_HOURS_PER_DAY:
            raise ValueError(f"Máximo {MAX_HOURS_PER_DAY} horas por día")
        return out


class AlertCreate(_ScheduleMixin):
    query: str = Field(min_length=2, max_length=200)
    target_price: int = Field(ge=1, le=100_000_000)
    days: list[int]
    hours: list[int]


class AlertUpdate(_ScheduleMixin):
    target_price: Optional[int] = Field(default=None, ge=1, le=100_000_000)
    days: Optional[list[int]] = None
    hours: Optional[list[int]] = None
    active: Optional[bool] = None


def _get_owned(s, alert_id: str, user_id: str) -> Alert:
    alert = s.get(Alert, alert_id)
    if alert is None or alert.user_id != user_id:
        raise HTTPException(404, "Alerta no encontrada")
    return alert


@router.post("/alerts")
def create_alert(body: AlertCreate, user_id: str = Depends(_user_id)):
    with SessionLocal() as s:
        count = len(list(s.scalars(select(Alert.id).where(Alert.user_id == user_id))))
        if count >= MAX_ALERTS_PER_USER:
            raise HTTPException(400, f"Máximo {MAX_ALERTS_PER_USER} alertas por usuario")
        alert = Alert(
            id=uuid.uuid4().hex,
            user_id=user_id,
            query=body.query.strip(),
            target_price=body.target_price,
            days=",".join(map(str, body.days)),
            hours=",".join(map(str, body.hours)),
            next_check_at=_now(),  # la primera revisión corre en el próximo minuto
        )
        s.add(alert)
        s.commit()
        return _alert_dict(alert)


@router.get("/alerts")
def list_alerts(user_id: str = Depends(_user_id)):
    with SessionLocal() as s:
        rows = s.scalars(
            select(Alert).where(Alert.user_id == user_id).order_by(Alert.created_at.desc())
        )
        return {"alerts": [_alert_dict(a) for a in rows]}


@router.patch("/alerts/{alert_id}")
def update_alert(alert_id: str, body: AlertUpdate, user_id: str = Depends(_user_id)):
    with SessionLocal() as s:
        alert = _get_owned(s, alert_id, user_id)
        if body.target_price is not None and body.target_price != alert.target_price:
            alert.target_price = body.target_price
            alert.notified = False  # con otro objetivo, que vuelva a avisar
        if body.days is not None or body.hours is not None:
            if body.days is not None:
                alert.days = ",".join(map(str, body.days))
            if body.hours is not None:
                alert.hours = ",".join(map(str, body.hours))
            alert.next_check_at = _next_slot(_csv_to_ints(alert.days), _csv_to_ints(alert.hours))
        if body.active is not None:
            alert.active = body.active
            if body.active:
                alert.next_check_at = _now()
        s.commit()
        return _alert_dict(alert)


@router.delete("/alerts/{alert_id}")
def delete_alert(alert_id: str, user_id: str = Depends(_user_id)):
    with SessionLocal() as s:
        alert = _get_owned(s, alert_id, user_id)
        s.delete(alert)
        s.commit()
    return {"deleted": True}


@router.post("/alerts/{alert_id}/check-now")
async def check_now(alert_id: str, user_id: str = Depends(_user_id)):
    with SessionLocal() as s:
        _get_owned(s, alert_id, user_id)
    return await check_alert(alert_id)


# --- Vinculación con Telegram ----------------------------------------------

@router.get("/telegram/status")
def telegram_status(user_id: str = Depends(_user_id)):
    with SessionLocal() as s:
        settings = s.get(UserSettings, user_id)
        linked = bool(settings and settings.telegram_chat_id)
    return {"linked": linked, "bot_configured": bool(os.getenv("TELEGRAM_BOT_TOKEN"))}


@router.post("/telegram/link")
def telegram_link(user_id: str = Depends(_user_id)):
    """Genera un enlace único (t.me/<bot>?start=<código>). Al abrirlo y tocar
    "Iniciar", el bot recibe el código y sabemos a qué usuario pertenece ese
    chat."""
    try:
        me = _tg_call("getMe")
    except TelegramError as exc:
        raise HTTPException(exc.status, str(exc)) from None
    code = secrets.token_urlsafe(8)
    with SessionLocal() as s:
        settings = s.get(UserSettings, user_id) or UserSettings(user_id=user_id)
        settings.link_code = code
        s.add(settings)
        s.commit()
    return {"code": code, "url": f"https://t.me/{me['username']}?start={code}"}


@router.post("/telegram/verify")
def telegram_verify(user_id: str = Depends(_user_id)):
    """Busca en los mensajes recientes del bot el "/start <código>" de este
    usuario y, si lo encuentra, guarda su chat para enviarle los avisos."""
    with SessionLocal() as s:
        settings = s.get(UserSettings, user_id)
        code = settings.link_code if settings else None
    if not code:
        raise HTTPException(400, "Primero pide el enlace de vinculación")

    try:
        updates = _tg_call("getUpdates", limit=100, timeout=0)
    except TelegramError as exc:
        raise HTTPException(exc.status, str(exc)) from None

    chat_id = None
    for update in reversed(updates):
        message = update.get("message") or {}
        if (message.get("text") or "").strip() == f"/start {code}":
            chat_id = str((message.get("chat") or {}).get("id"))
            break
    if not chat_id:
        return {"linked": False}

    with SessionLocal() as s:
        settings = s.get(UserSettings, user_id)
        settings.telegram_chat_id = chat_id
        settings.link_code = None
        s.commit()
    try:
        _tg_call(
            "sendMessage",
            chat_id=chat_id,
            text="Telegram vinculado. Aquí te avisaré cuando un producto llegue a tu precio objetivo.",
        )
    except TelegramError:
        pass  # quedó vinculado igual; el mensaje de bienvenida es solo cortesía
    return {"linked": True}
