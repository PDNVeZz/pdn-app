# App móvil (Flutter)

Esta carpeta está vacía a propósito. Flutter genera automáticamente las carpetas
nativas de iOS/Android según la versión instalada en tu máquina, así que es mejor
que las genere tu propio Flutter local en vez de copiar carpetas ya generadas.

## Para arrancar

Desde la terminal de VS Code, parado en esta carpeta (`mobile/`):

```bash
flutter create .
flutter pub get
flutter run
```

Esto crea `lib/main.dart`, `pubspec.yaml`, `ios/`, `android/`, etc.

## Conectar con el backend

Una vez desplegado el backend en Railway, vas a tener una URL tipo
`https://tu-backend.up.railway.app`. Guárdala en algún lugar central de la app
(por ejemplo `lib/config.dart`) para que las pantallas de "sacar foto" y
"comparar precios" apunten ahí.

Los dos endpoints principales que expone el backend:

- `POST /identify-product` — multipart/form-data con el campo `file` (la foto).
  Devuelve `{ "product_name": "..." }`.
- `POST /search-prices` — JSON `{ "query": "nombre del producto" }`.
  Devuelve los resultados de Falabella, Ripley, Paris y Ahumada.
