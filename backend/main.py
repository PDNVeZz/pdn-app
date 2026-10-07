"""
Backend de la app de comparación de precios.

Flujo:
1. El usuario saca una foto de un producto en la app móvil.
2. POST /identify-product -> Claude (visión) identifica qué producto es.
3. POST /search-prices -> corremos actores de Apify sobre Falabella, Ripley,
   Paris y Ahumada en paralelo para buscar ese producto y comparar precios.

Esto es un esqueleto funcional para arrancar el desarrollo. Los actores de
Apify y sus parámetros de entrada hay que ajustarlos según el formato real
de cada actor (revisa la pestaña "Input" de cada actor en tu cuenta Apify).
"""

import asyncio
import base64
import io
import json
import os
import re
import unicodedata

from dotenv import load_dotenv
from fastapi import FastAPI, File, HTTPException, Query, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import Response
from PIL import Image
from pydantic import BaseModel

import anthropic
import pillow_heif
import requests
from apify_client import ApifyClientAsync

# Permite que Pillow abra fotos HEIC/HEIF (el formato nativo de iPhone),
# que Claude no acepta directamente.
pillow_heif.register_heif_opener()

load_dotenv()

app = FastAPI(title="PDN API", version="0.1.0")

# Permite que la app (Flutter web en localhost, o la app móvil) llame a esta
# API desde otro origen. En desarrollo dejamos "*" (cualquier origen); antes
# de publicar la app de verdad, conviene restringirlo a los dominios reales.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY")
APIFY_TOKEN = os.getenv("APIFY_TOKEN")

STORE_ACTORS = {
    "falabella": os.getenv("APIFY_ACTOR_FALABELLA"),
    "ripley": os.getenv("APIFY_ACTOR_RIPLEY"),
    "paris": os.getenv("APIFY_ACTOR_PARIS"),
    "ahumada": os.getenv("APIFY_ACTOR_AHUMADA"),
}

# Parámetros extra por tienda, además de "term". El actor de Falabella tiene
# un bug conocido: si intenta traer varias páginas de resultados, a veces
# Falabella cambia el conteo de paginación entre una página y otra y el
# actor lanza una excepción y aborta toda la corrida. Limitándolo a 1 página
# evitamos que dispare ese caso.
STORE_EXTRA_INPUT = {
    "falabella": {"maxPages": 1},
}
anthropic_client = anthropic.Anthropic(api_key=ANTHROPIC_API_KEY) if ANTHROPIC_API_KEY else None
apify_client = ApifyClientAsync(APIFY_TOKEN) if APIFY_TOKEN else None


class SearchPricesRequest(BaseModel):
    query: str


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/image-proxy")
def image_proxy(url: str = Query(..., description="URL de la imagen del producto a reenviar")):
    """Descarga una imagen de producto y la reenvía a la app.

    Varias tiendas (Paris, Ripley, Ahumada) bloquean que su imagen se cargue
    directamente desde otro sitio o app (protección anti-hotlinking / CORS
    del navegador). Como esta petición la hace el backend y no el navegador
    de la app, esa restricción no aplica: descargamos la imagen acá y se la
    entregamos a Flutter como si fuera propia.
    """
    if not (url.startswith("http://") or url.startswith("https://")):
        raise HTTPException(400, "URL de imagen inválida")

    try:
        resp = requests.get(
            url,
            timeout=10,
            headers={
                # Algunas tiendas revisan el User-Agent y rechazan clientes
                # que no parezcan un navegador normal.
                "User-Agent": (
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) "
                    "Chrome/120.0.0.0 Safari/537.36"
                ),
            },
        )
        resp.raise_for_status()
    except Exception as exc:  # noqa: BLE001
        print(f"[image-proxy] ERROR descargando {url!r}: {exc!r}", flush=True)
        raise HTTPException(502, f"No se pudo obtener la imagen: {exc}") from exc

    content_type = resp.headers.get("Content-Type", "image/jpeg")
    return Response(
        content=resp.content,
        media_type=content_type,
        headers={"Cache-Control": "public, max-age=86400"},
    )


@app.post("/identify-product")
async def identify_product(file: UploadFile = File(...)):
    """Recibe una foto y devuelve el nombre/marca del producto detectado."""
    if not anthropic_client:
        raise HTTPException(500, "Falta configurar ANTHROPIC_API_KEY en el .env")

    original_bytes = await file.read()

    print(
        f"[identify-product] archivo recibido: filename={file.filename!r} "
        f"content_type={file.content_type!r} bytes={len(original_bytes)} "
        f"primeros_bytes={original_bytes[:12]!r}",
        flush=True,
    )

    if len(original_bytes) == 0:
        raise HTTPException(400, "La imagen llegó vacía (0 bytes) al backend.")

    # Convertimos SIEMPRE a JPEG, sin importar el formato de origen (HEIC de
    # iPhone, PNG, WEBP, etc.). Así evitamos que Claude rechace formatos que
    # no soporta o content_types mal etiquetados por el navegador/celular.
    try:
        image = Image.open(io.BytesIO(original_bytes))
        if image.mode not in ("RGB", "L"):
            image = image.convert("RGB")
        buffer = io.BytesIO()
        image.save(buffer, format="JPEG", quality=90)
        image_bytes = buffer.getvalue()
    except Exception as exc:  # noqa: BLE001
        print(f"[identify-product] ERROR convirtiendo la imagen: {exc!r}", flush=True)
        raise HTTPException(
            400, f"No se pudo procesar el archivo de imagen ({exc}). Prueba con otra foto."
        ) from exc

    media_type = "image/jpeg"
    image_b64 = base64.b64encode(image_bytes).decode("utf-8")

    try:
        message = anthropic_client.messages.create(
            model="claude-opus-4-5",
            max_tokens=300,
            messages=[
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "image",
                            "source": {
                                "type": "base64",
                                "media_type": media_type,
                                "data": image_b64,
                            },
                        },
                        {
                            "type": "text",
                            "text": (
                                "Identifica el producto en esta foto. Responde SOLO con el "
                                "nombre del producto y la marca, tal como lo buscarías en una "
                                "tienda online (ej: 'Notebook Lenovo IdeaPad 3 15.6 8GB 256GB'). "
                                "Sin explicaciones adicionales."
                            ),
                        },
                    ],
                }
            ],
        )
    except Exception as exc:  # noqa: BLE001 - queremos ver el motivo real en la app
        print(f"[identify-product] ERROR llamando a Anthropic: {exc!r}", flush=True)
        raise HTTPException(500, f"Error llamando a Claude: {exc}") from exc

    try:
        product_name = message.content[0].text.strip()
    except Exception as exc:  # noqa: BLE001
        print(f"[identify-product] ERROR leyendo la respuesta: {exc!r} / message={message}", flush=True)
        raise HTTPException(500, f"Respuesta inesperada de Claude: {exc}") from exc

    return {"product_name": product_name}


def _parse_price_number(value) -> float | None:
    """Convierte un precio que puede venir como número (14990) o como texto
    con separador de miles chileno (ej: "17.990") a un número, para poder
    compararlos entre sí."""
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value) if value > 0 else None
    if isinstance(value, str):
        digits = re.sub(r"[^0-9]", "", value)
        if digits:
            return float(digits)
    return None


def _normalize_falabella_price(item: dict) -> None:
    """Falabella no trae un único precio "correcto": puede venir en varios
    campos de nivel superior (internet_price, normal_price, cmr_price) y
    además dentro de "raw_product" hay una lista de precios con distintos
    tipos (normalPrice, eventPrice, cmrPrice, etc). El problema es que
    varios de esos son precios "antes de descuento" (tachados en la
    página) y no el precio real que se paga: por ejemplo, "normal_price"
    puede ser justamente ese precio tachado.

    En vez de asumir cuál campo es el correcto, juntamos TODOS los precios
    que encontramos y nos quedamos con el más bajo: el precio con
    descuento siempre es menor que los precios "antes", así que el mínimo
    es, en la práctica, el precio real de venta.
    """
    candidates: list[float] = []

    for field in ("internet_price", "normal_price", "cmr_price"):
        parsed = _parse_price_number(item.get(field))
        if parsed:
            candidates.append(parsed)

    try:
        raw = json.loads(item.get("raw_product") or "{}")
        for price_entry in raw.get("prices", []):
            price_list = price_entry.get("price")
            if price_list:
                parsed = _parse_price_number(price_list[0])
                if parsed:
                    candidates.append(parsed)
    except Exception:  # noqa: BLE001 - si el JSON viene raro, seguimos con lo que tengamos
        pass

    if candidates:
        item["price"] = f"${min(candidates):,.0f}".replace(",", ".")


_STOPWORDS = {
    "para", "de", "la", "el", "los", "las", "con", "y", "a", "un", "una",
    "del", "en", "por", "que", "su", "sus", "o",
}


def _normalize_text(text: str) -> str:
    """Quita tildes/acentos y pasa a minúsculas, para poder comparar
    "cámara" con "camara" sin que la tilde arruine la comparación."""
    text = unicodedata.normalize("NFKD", text or "")
    text = "".join(ch for ch in text if not unicodedata.combining(ch))
    return text.lower()


def _query_tokens(query: str) -> list[str]:
    words = re.findall(r"\w+", _normalize_text(query))
    return [w for w in words if w not in _STOPWORDS and len(w) > 1]


def _item_title(item: dict) -> str:
    for key in ("name", "title", "displayName", "product_name"):
        value = item.get(key)
        if value:
            return str(value)
    return ""


def _relevance_score(tokens: list[str], text: str) -> int:
    normalized = _normalize_text(text)
    return sum(1 for token in tokens if token in normalized)


def _rank_by_relevance(items: list[dict], query: str):
    """Los actores de Apify a veces devuelven productos que no tienen nada
    que ver con lo buscado (ej: buscar una cámara digital infantil y que
    aparezca primero una bicicleta infantil, porque ambas comparten
    palabras sueltas como "infantil" o "niño"). Reordenamos los resultados
    según cuántas palabras de la búsqueda aparecen en el nombre del
    producto, para que lo más relevante quede primero en vez de confiar
    ciegamente en el orden que entrega la tienda.

    Devuelve None si la búsqueda no tiene palabras útiles para comparar
    (en ese caso no reordenamos ni filtramos nada).
    """
    tokens = _query_tokens(query)
    if not tokens:
        return None

    scored = [
        (_relevance_score(tokens, _item_title(item)), idx, item)
        for idx, item in enumerate(items)
    ]
    scored.sort(key=lambda entry: (-entry[0], entry[1]))
    return [(score, item) for score, _idx, item in scored]


async def _search_store(store: str, actor_id: str, query: str):
    """Corre el actor de Apify de una tienda y devuelve resultados normalizados."""
    if not actor_id:
        return {"store": store, "results": [], "error": "actor no configurado"}

    run_input = {"term": query, **STORE_EXTRA_INPUT.get(store, {})}

    try:
        run = await apify_client.actor(actor_id).call(run_input=run_input)
        # Según la versión de apify-client, `run` puede ser un dict o un
        # objeto con atributos. Probamos ambas formas para no depender de
        # una versión específica.
        if isinstance(run, dict):
            dataset_id = run["defaultDatasetId"]
        else:
            dataset_id = run.default_dataset_id
        items = []
        async for item in apify_client.dataset(dataset_id).iterate_items():
            items.append(item)

        ranked = _rank_by_relevance(items, query)
        if ranked is not None and (not ranked or ranked[0][0] == 0):
            # Ni el mejor resultado comparte una sola palabra con la
            # búsqueda: mejor decir que no se encontró a mostrar un
            # producto que no tiene nada que ver.
            print(
                f"[search-prices] {store}: {len(items)} resultado(s) traídos, "
                f"ninguno relevante para {query!r}",
                flush=True,
            )
            return {"store": store, "results": [], "error": "No se encontró un producto relevante"}

        ordered_items = [item for _score, item in ranked] if ranked is not None else items
        top_items = ordered_items[:5]
        if store == "falabella":
            for item in top_items:
                _normalize_falabella_price(item)

        print(
            f"[search-prices] {store}: {len(items)} resultado(s). "
            f"Primer item: {top_items[0] if top_items else None}",
            flush=True,
        )
        return {"store": store, "results": top_items, "error": None}
    except Exception as exc:  # noqa: BLE001 - queremos que un error en una tienda no tumbe todo
        print(f"[search-prices] {store}: ERROR {exc!r}", flush=True)
        return {"store": store, "results": [], "error": str(exc)}


@app.post("/search-prices")
async def search_prices(body: SearchPricesRequest):
    """Busca el producto en las 4 tiendas en paralelo y devuelve la comparación."""
    if not apify_client:
        raise HTTPException(500, "Falta configurar APIFY_TOKEN en el .env")

    tasks = [
        _search_store(store, actor_id, body.query)
        for store, actor_id in STORE_ACTORS.items()
    ]
    results = await asyncio.gather(*tasks)
    return {"query": body.query, "stores": results}
