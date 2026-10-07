/// Configuración central de la app.
///
/// El backend está desplegado en Railway, así que la app ya no depende de que
/// tu computador esté prendido corriendo `uvicorn`. Funciona igual desde
/// Chrome, un emulador o un celular físico, porque la URL es pública.
///
/// Para volver a probar contra tu backend local (`uvicorn main:app`), cambia
/// el valor por "http://127.0.0.1:8000". En un emulador Android usa
/// "http://10.0.2.2:8000" en su lugar.
const String backendBaseUrl = "https://pdn-app-production.up.railway.app";
