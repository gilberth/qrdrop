# QRDrop

Transferencia de archivos temporal vía QR: **subida única, descarga directa, autoborrado.**
Self-hosted, sin cuentas, sin base de datos externa, sin dependencias de nube.

Subes un archivo desde un dispositivo, la web te muestra un QR grande. El otro
dispositivo lo escanea con la cámara y la descarga **arranca sola** — sin landing
page, sin botones intermedios. Apenas termina, el archivo se borra del servidor.

Funciona igual si el receptor está en tu LAN o con datos móviles al otro lado del
país: solo necesita alcanzar tu dominio público (p. ej. vía Cloudflare Tunnel).

## Cómo funciona

```
Dispositivo A                    QRDrop                     Dispositivo B
     │                             │                              │
     │──── POST /api/upload ──────>│                              │
     │                             │ guarda en /data/<token>/     │
     │<─── token + QR + expira ────│                              │
     │                             │                              │
     │  muestra QR ────────── escanea con la cámara ─────────────>│
     │                             │                              │
     │                             │<──── GET /d/<token> ─────────│
     │                             │ Content-Disposition:         │
     │                             │ attachment  (stream directo) │
     │                             │─────── el archivo ──────────>│
     │                             │ borra /data/<token>/         │
```

- **Un solo uso.** Completada la descarga, el archivo desaparece del disco.
- **Expiración.** Si nadie lo descarga, se borra solo (2 h por defecto).
- **Reintentable.** Si la descarga se corta a mitad, el archivo *no* se borra:
  el mismo enlace sirve para reintentar hasta que se complete o expire.
- **Token no adivinable.** 18 bytes de `crypto.randomBytes` en base64url.

## Requisitos

- Node.js 20 o superior (probado en 22 LTS), **o** solo Docker.

## Uso local

```bash
npm install
cp .env.example .env      # opcional: ajusta límites
DATA_DIR=./data npm start
```

Abre http://localhost:3000

Para desarrollo con recarga automática:

```bash
DATA_DIR=./data npm run dev
```

> `DATA_DIR` por defecto es `/data` (pensado para el contenedor). En local conviene
> apuntarlo a `./data` como en los ejemplos.

## Imagen Docker publicada

Un workflow de GitHub Actions (`.github/workflows/docker-image.yml`) construye
y publica la imagen en GitHub Container Registry en cada push a `main`, cada
tag `vX.Y.Z` y manualmente vía "Run workflow". Los pull request solo compilan
la imagen para validar el `Dockerfile`, sin publicar nada.

No requiere configurar ningún secreto: usa el `GITHUB_TOKEN` que GitHub
Actions ya provee. La primera vez que publique, marca el paquete como público
en Settings → Packages del repo si quieres poder hacer `docker pull` sin
autenticarte.

```bash
docker pull ghcr.io/gilberth/qrdrop:latest
```

Tags que genera: `latest` (rama `main`), `<versión>` y `<major>.<minor>`
(cuando se etiqueta un release, ej. `v1.2.0`), y el hash corto del commit.
Se construye para `linux/amd64` y `linux/arm64`.

## Uso con Docker Compose

```bash
cp .env.example .env       # define al menos PUBLIC_BASE_URL si usas un dominio
docker compose up -d --build
docker compose logs -f
```

El volumen `./data` del host queda mapeado a `/data` en el contenedor. El
contenedor corre como usuario no-root (`node`) y trae `HEALTHCHECK` contra
`/health`.

Para parar y limpiar:

```bash
docker compose down
```

## Variables de entorno

| Variable | Default | Descripción |
|---|---|---|
| `PORT` | `3000` | Puerto HTTP donde escucha la app. |
| `DATA_DIR` | `/data` | Carpeta de archivos y metadata. |
| `MAX_FILE_SIZE_MB` | `500` | Tamaño máximo por archivo. |
| `MAX_TTL_MINUTES` | `1440` | Tope de vida de un enlace (24 h). |
| `DEFAULT_TTL_MINUTES` | `120` | Vida por defecto (2 h). |
| `PUBLIC_BASE_URL` | *(vacío)* | URL pública con la que se arma el QR. **Ver abajo.** |
| `RATE_LIMIT_MAX` | `20` | Subidas permitidas por ventana y por IP. |
| `RATE_LIMIT_WINDOW_MINUTES` | `15` | Duración de esa ventana. |

Los límites se validan **en el servidor**, no solo en el frontend.

### Sobre `PUBLIC_BASE_URL`

Es lo único que suele hacer falta configurar bien. El QR debe contener la URL que
el celular del receptor pueda resolver — si apunta a `http://localhost:3000`, el
escaneo no sirve de nada.

La URL se resuelve con esta prioridad:

1. `PUBLIC_BASE_URL` si está definida.
2. Cabeceras `X-Forwarded-Proto` / `X-Forwarded-Host` (las que pone Cloudflare
   Tunnel y la mayoría de reverse proxies). La app arranca con `trust proxy`
   activado para respetarlas.
3. El `Host` del request (caso de acceso directo por LAN).

Detrás de un túnel funciona sin configurar nada gracias al punto 2, pero
**definir `PUBLIC_BASE_URL` explícitamente es lo recomendado**: es determinista y
no depende de que el proxy mande las cabeceras.

## Exponer con Cloudflare Tunnel

Fragmento de referencia para tu `config.yml` de `cloudflared` (la configuración
real del túnel corre por tu cuenta):

```yaml
- hostname: share.gytech.com.pe
  service: http://localhost:3000
```

Y en el `.env` de QRDrop:

```
PUBLIC_BASE_URL=https://share.gytech.com.pe
```

## Endpoints

| Método | Ruta | Descripción |
|---|---|---|
| `GET` | `/` | Frontend de subida. |
| `POST` | `/api/upload` | Multipart, campo `file`, un archivo. Query opcional `?ttl=<minutos>`. |
| `GET` | `/d/:token` | Descarga directa. Responde el binario con `Content-Disposition: attachment`. |
| `GET` | `/api/limits` | Límites del servidor, para que el frontend los muestre. |
| `GET` | `/health` | `{ status, uptime, activeFiles }`. Usado por el `HEALTHCHECK`. |

Ejemplo con `curl`:

```bash
# subir con vida de 30 minutos
curl -F "file=@informe.pdf" "http://localhost:3000/api/upload?ttl=30"

# descargar (conserva el nombre original)
curl -OJ "http://localhost:3000/d/<token>"
```

## Almacenamiento

Cada archivo vive en `/data/<token>/<nombre-original-sanitizado>`. La metadata va
en `/data/meta.json`, escrita de forma atómica (archivo temporal + `rename`), sin
base de datos externa. Al arrancar, la app carga ese JSON, barre lo expirado y
elimina carpetas huérfanas que hayan quedado de un apagado abrupto.

Un job en memoria corre cada 5 minutos y borra:

- todo lo que tenga `expiresAt` en el pasado;
- lo ya descargado hace más de 10 minutos (margen para que el emisor alcance a
  ver la confirmación en pantalla).

Cada barrido loguea a stdout cuántos archivos eliminó y cuánto espacio liberó.

## Seguridad

- Nombres de archivo sanitizados: se descarta cualquier componente de ruta, así
  que no hay path traversal.
- `helmet` con CSP restrictiva. Sin `upgrade-insecure-requests`, para que el
  acceso por `http://` en LAN siga funcionando.
- Rate limiting configurable en `/api/upload`.
- `/data` nunca se sirve como estático y no existe endpoint que liste archivos:
  sin el token no hay forma de llegar a nada.
- Sin cuentas, sin cookies, sin analytics, sin tracking.

Los tokens son la única credencial. Cualquiera con el enlace puede descargar el
archivo una vez — que es justamente la idea. No pongas aquí nada que no puedas
permitirte que se filtre si el QR queda a la vista de un tercero.

## Posibles mejoras

- Varios archivos en un solo QR (empaquetados en un zip al vuelo).
- Límite de descargas configurable en vez de uso único fijo.
- Cifrado del lado del cliente con la clave en el fragmento de la URL, para que
  el servidor nunca vea el contenido en claro.
