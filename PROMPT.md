# Prompt para Claude Code — QRDrop

Copia y pega esto en Claude Code dentro de este repo (`qrdrop`) para que construya la aplicación completa.

---

## Contexto

Necesito una aplicación web self-hosted para transferir archivos entre dispositivos sin depender de que ambos estén en la misma red local (debe funcionar aunque el receptor esté con datos móviles). El flujo es:

1. Un dispositivo (A) abre la web, sube un archivo (drag & drop o selector).
2. Al terminar la subida, la web muestra un **QR grande** apuntando a una URL pública de descarga (`https://<dominio>/d/<token>`), más el link en texto y un botón "copiar".
3. El otro dispositivo (B) escanea el QR con la cámara del celular → se abre el navegador → la descarga **arranca automáticamente** (sin landing page intermedia, sin botones extra: el servidor responde directo con `Content-Disposition: attachment`).
4. Una vez completada la descarga, el archivo se **borra del servidor** (uso único). También debe expirar y autoborrarse si nadie lo descarga dentro de un tiempo configurable (default: 2 horas).
5. Todo debe funcionar con el mecanismo estándar de descargas del navegador (no requiere Service Worker, PWA, ni nada especial de caché — el navegador maneja el archivo descargado igual que cualquier descarga normal una vez que sale del servidor).

## Stack técnico requerido

- **Backend:** Node.js + Express (LTS actual)
- **Frontend:** HTML/CSS/JS vanilla en un único archivo estático servido por Express (sin frameworks pesados). Usa la librería `qrcode` (o `qrcode.js` vía CDN) para generar el QR en el cliente o servidor — decide tú la mejor opción.
- **Almacenamiento:** filesystem local dentro de un volumen Docker (`/data`), sin base de datos externa. Usa un JSON simple o SQLite (better-sqlite3) para metadata (token, filename, mimetype, tamaño, timestamp de creación, expiración, estado descargado).
- **Contenedor:** Dockerfile + docker-compose.yml, imagen Node alpine, corre como usuario no-root.
- **Sin dependencias de nube:** todo debe poder correr 100% offline dentro de mi red, expuesto después vía Cloudflare Tunnel (eso lo configuro yo aparte, tú solo entrega la app escuchando en un puerto HTTP configurable por variable de entorno `PORT`, default 3000).

## Requisitos funcionales detallados

### Upload (`POST /api/upload`)
- Multipart, un archivo por request (límite configurable por env `MAX_FILE_SIZE_MB`, default 500).
- Genera un `token` aleatorio y no adivinable (usa `crypto.randomBytes`, no UUID incremental — mínimo 16 bytes en base64url).
- Guarda el archivo en `/data/<token>/<filename-original-sanitizado>`.
- Guarda metadata: `token`, `filename`, `size`, `mimetype`, `createdAt`, `expiresAt` (default createdAt + 2h, configurable vía query param `ttl` en minutos con máximo permitido por env `MAX_TTL_MINUTES`), `downloaded: false`.
- Responde JSON: `{ token, downloadUrl, expiresAt }`. El frontend arma la URL completa con `window.location.origin` (o usa una env `PUBLIC_BASE_URL` si se define, porque detrás de Cloudflare Tunnel el origin puede no coincidir con el dominio público — dale prioridad a `PUBLIC_BASE_URL` si existe).
- Muestra barra de progreso real durante la subida (usa `XMLHttpRequest` con `upload.onprogress`, fetch no soporta progreso de subida de forma nativa).

### Descarga directa (`GET /d/:token`)
- Si el token no existe, ya fue descargado, o expiró → responde 404 con una página simple de error (texto plano está bien, sin diseño elaborado) y limpia el archivo si aún existiera.
- Si es válido:
  - Responde el archivo directo con headers `Content-Disposition: attachment; filename="<original>"` y `Content-Type` correcto — el navegador debe iniciar la descarga inmediatamente, sin HTML intermedio.
  - Usa streaming (`fs.createReadStream` + `pipe`), no cargues el archivo completo en memoria.
  - **Al terminar el stream exitosamente** (evento `end`/`close` del response), marca el registro como descargado y borra el archivo y su carpeta de `/data`. Si la conexión se corta a mitad de la descarga, NO borres el archivo (para permitir reintentar), pero si expira mientras tanto sí se limpia por el cron.

### Limpieza / expiración
- Job en memoria (`setInterval`, cada 5 minutos) que recorre la metadata y borra archivos con `expiresAt < now` o `downloaded: true` con más de 10 minutos de antigüedad (grace period por si el usuario quiere ver confirmación).
- Log simple a stdout de cada limpieza (cuántos archivos, cuánto espacio liberado).

### Frontend (una sola página, `/`)
- Diseño simple, responsive, mobile-first (muchos usuarios lo van a abrir desde el celular para escanear o para subir).
- Zona de drag & drop + botón de selección de archivo tradicional.
- Barra de progreso durante la subida.
- Al completar: mostrar el QR (grande, mínimo 250x250px), el link completo en un input de solo lectura + botón "Copiar", tamaño del archivo, y un contador de expiración ("Expira en 1h 58m", actualizado cada minuto).
- Mensaje claro de que el archivo se borra automáticamente al descargarse o al expirar.
- Sin analytics, sin dependencias externas más allá del CDN de la librería QR (o bundlear la librería localmente, mejor aún para que funcione sin internet en LAN pura).
- Nada de cuentas, login, ni tracking.

### Seguridad básica
- Sanitiza el nombre de archivo original (evita path traversal).
- Rate limiting simple en `/api/upload` (usa `express-rate-limit`, ej. 20 uploads cada 15 min por IP — configurable).
- Headers de seguridad básicos (usa `helmet`).
- No expongas listado de archivos ni la carpeta `/data` como estática.
- Válida `MAX_TTL_MINUTES` y `MAX_FILE_SIZE_MB` en servidor, no solo en frontend.

## Variables de entorno

```
PORT=3000
DATA_DIR=/data
MAX_FILE_SIZE_MB=500
MAX_TTL_MINUTES=1440
DEFAULT_TTL_MINUTES=120
PUBLIC_BASE_URL=            # opcional, ej. https://share.gytech.com.pe
RATE_LIMIT_MAX=20
RATE_LIMIT_WINDOW_MINUTES=15
```

## Entregables

1. `server.js` (o estructura modular en `src/` si prefieres — usa tu criterio, pero mantenlo simple, esto no necesita ser una arquitectura enterprise).
2. `public/index.html` con CSS y JS inline o en archivos separados dentro de `public/`.
3. `package.json` con scripts `start` y `dev` (usa `nodemon` en dev).
4. `Dockerfile` (multi-stage si aporta valor, imagen final alpine, usuario no-root, `HEALTHCHECK` que golpee un endpoint `/health`).
5. `docker-compose.yml` con el volumen `/data` mapeado a `./data` local, variables de entorno con valores default, y `restart: unless-stopped`.
6. `.env.example`.
7. `.dockerignore` y `.gitignore` (node_modules, data/, .env).
8. `README.md` con instrucciones de build/run local y con Docker Compose, y una sección de ejemplo de config de Cloudflare Tunnel (solo como referencia en texto, no necesitas generar la config real):
   ```yaml
   - hostname: share.gytech.com.pe
     service: http://localhost:3000
   ```
9. Endpoint `GET /health` que responda `{ status: "ok", uptime, activeFiles }`.

## Cosas a NO hacer

- No agregues autenticación de usuarios ni base de datos externa (Postgres, MySQL, etc.) — es innecesario para este caso de uso.
- No uses WebSockets ni polling agresivo para el progreso; XHR upload progress es suficiente.
- No implementes compartir múltiples archivos en un solo QR en esta primera versión (puede quedar como posible mejora futura en el README, pero no lo construyas ahora).
- No hardcodees ningún dominio ni secreto.

## Criterio de aceptación

- `docker compose up` levanta la app y en `http://localhost:3000` puedo subir un archivo, ver el QR, y al abrir el link de descarga en otra pestaña/dispositivo el archivo se descarga directo y desaparece del volumen `/data` después.
- Si dejo un archivo sin descargar y paso el tiempo de expiración, el cron lo elimina solo (verificable bajando `DEFAULT_TTL_MINUTES` a 1 para probar rápido).
- El código está comentado donde no sea obvio, pero sin exceso de verbosidad.

Construye la app completa, corre `npm install` para validar que no hay errores, y déjala lista para build de Docker.
