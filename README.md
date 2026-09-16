# PDN Project — App de comparación de precios (Falabella, Ripley, Paris, Ahumada)

Este es el punto de partida del proyecto. La Fase 1 (cuentas y herramientas) ya está lista:
Gmail del negocio, Anthropic Console, Railway, Apify, GitHub, y las herramientas locales
(Python, Flutter, VS Code, Claude Code).

## Estructura

```
PDN project/
├── backend/          # API en Python (FastAPI) — identifica productos por foto y compara precios
│   ├── main.py
│   ├── requirements.txt
│   └── Procfile       # para desplegar en Railway
├── mobile/            # App Flutter (iOS + Android)
│   └── README.md
├── .env.example        # variables de entorno necesarias (copiar a .env y rellenar)
└── .gitignore
```

## Próximos pasos (hazlo tú en VS Code, en la terminal, dentro de esta carpeta)

No tengo acceso a una terminal en tu computador, así que estos comandos los corres tú
directamente en VS Code (Terminal → New Terminal), parado en esta carpeta.

### 1. Conectar con Git y GitHub

```bash
git init
git add .
git commit -m "Estructura inicial del proyecto"
git branch -M main
git remote add origin https://github.com/TU-USUARIO/TU-REPO.git
git push -u origin main
```

(Crea antes el repositorio vacío en github.com/new, sin README, y reemplaza la URL de arriba
por la que te da GitHub.)

### 2. Backend (Python)

```bash
cd backend
python -m venv venv
venv\Scripts\activate        # en Windows
pip install -r requirements.txt
copy ..\.env.example ..\.env  # y rellena tus API keys ahí
uvicorn main:app --reload
```

Abre http://localhost:8000/docs para ver la API funcionando.

### 3. Mobile (Flutter)

```bash
cd mobile
flutter create .
flutter pub get
flutter run
```

Esto genera automáticamente las carpetas nativas de iOS/Android (por eso no las incluyo
yo — las genera el propio Flutter instalado en tu máquina).

### 4. Conectar Railway (deploy del backend)

En railway.app: New Project → Deploy from GitHub repo → selecciona este repo → Railway
detecta el backend y lo despliega. Después, en el proyecto de Railway, agrega las variables
de entorno (las mismas de tu `.env`) en Settings → Variables.

### 5. Conectar Apify

Ya tienes los actores de Falabella, Ripley, Paris y Ahumada disponibles en tu cuenta Apify.
En `.env`, agrega el `APIFY_TOKEN` (lo encuentras en apify.com → Settings → Integrations →
API tokens) y los IDs de cada actor (Apify → Actors → clic en cada uno → arriba dice el ID,
formato `usuario/nombre-actor`).

## Variables de entorno necesarias (ver `.env.example`)

- `ANTHROPIC_API_KEY` — de console.anthropic.com, para identificar el producto por foto.
- `APIFY_TOKEN` — de apify.com, para correr los scrapers de las tiendas.
- `APIFY_ACTOR_FALABELLA`, `APIFY_ACTOR_RIPLEY`, `APIFY_ACTOR_PARIS`, `APIFY_ACTOR_AHUMADA` —
  IDs de cada actor de Apify.
