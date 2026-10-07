/// Configuración central de la app.
///
/// Mientras el backend corre en tu computador (`uvicorn main:app`), usa
/// 127.0.0.1. Cuando lo despleguemos en Railway, reemplaza este valor por
/// la URL pública que te dé Railway (algo como
/// "https://tu-backend.up.railway.app").
///
/// Nota para cuando pruebes en un emulador Android: el emulador no ve
/// "127.0.0.1" de tu PC como localhost — usa "10.0.2.2" en su lugar.
/// En Chrome (web) o en un celular físico conectado por USB con
/// "flutter run", 127.0.0.1 / la IP de tu red funciona distinto según el
/// caso; una vez desplegado en Railway esto deja de ser un problema porque
/// la URL es pública y funciona igual desde cualquier lado.
const String backendBaseUrl = "http://127.0.0.1:8000";
