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
import os

from dotenv import load_dotenv
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from PIL import Image
from pydantic import BaseModel

import anthropic
import pillow_heif
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

anthropic_client = anthropic.Anthropic(api_key=ANTHROPIC_API_KEY) if ANTHROPIC_API_KEY else None
apify_client = ApifyClientAsync(APIFY_TOKEN) if APIFY_TOKEN else None


class SearchPricesRequest(BaseModel):
    query: str


@app.get("/health")
def health():
    return {"status": "ok"}


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


async def _search_store(store: str, actor_id: str, query: str):
    """Corre el actor de Apify de una tienda y devuelve resultados normalizados."""
    if not actor_id:
        return {"store": store, "results": [], "error": "actor no configurado"}

    try:
        run = await apify_client.actor(actor_id).call(run_input={"term": query})
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
        print(
            f"[search-prices] {store}: {len(items)} resultado(s). "
            f"Primer item: {items[0] if items else None}",
            flush=True,
        )
        return {"store": store, "results": items[:5], "error": None}
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
