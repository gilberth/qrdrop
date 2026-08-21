# Instalación sin Docker (LXC / VM Debian o Ubuntu)

Para correr QRDrop directo sobre un LXC o VM sin pasar por Docker: instala
Node.js si hace falta, crea un usuario de sistema sin privilegios, clona el
repo, instala dependencias y deja un servicio `systemd` corriendo como ese
usuario.

## Instalación

```bash
curl -fsSL https://raw.githubusercontent.com/gilberth/qrdrop/main/install/install.sh \
  | sudo bash -s -- --domain https://share.gytech.com.pe
```

> Los templates LXC mínimos de Proxmox (Debian 12/13 `standard`) no traen
> `curl` de fábrica. Si te falla con `command not found`, corré primero
> `apt-get update && apt-get install -y curl ca-certificates`.

Sin `--domain`, el QR se arma con la IP/host del LXC — sirve para probar en
LAN, pero para que funcione detrás de un Cloudflare Tunnel hace falta pasar
la URL pública (equivale a `PUBLIC_BASE_URL`).

Todo lo que hace el script:

1. Instala `git`, `ca-certificates`, `gnupg` si faltan.
2. Instala Node.js 22.x vía NodeSource si el que hay es menor a 20 (los
   scripts `package.json` piden Node ≥ 20).
3. Crea un usuario de sistema sin shell (`qrdrop` por defecto) — la app nunca
   corre como root.
4. Clona el repo en `/opt/qrdrop` (o el `--dir` que indiques).
5. Corre `npm ci --omit=dev` como ese usuario.
6. Escribe `/opt/qrdrop/.env` con la configuración (permisos `600`).
7. Genera y habilita `/etc/systemd/system/qrdrop.service`.
8. Verifica que `/health` responda antes de terminar.

## Actualizar

Volver a correr el mismo comando actualiza una instalación existente en vez
de romperla: hace `git fetch` + reset al `--ref` indicado (default `main`),
reinstala dependencias y reinicia el servicio. La carpeta de datos y el
`.env` no se tocan.

```bash
curl -fsSL https://raw.githubusercontent.com/gilberth/qrdrop/main/install/install.sh \
  | sudo bash -s -- --domain https://share.gytech.com.pe
```

## Flags

| Flag | Default | Descripción |
|---|---|---|
| `--dir` | `/opt/qrdrop` | Carpeta de instalación |
| `--data-dir` | `<dir>/data` | Carpeta de archivos subidos |
| `--name` | `qrdrop` | Nombre del usuario y del servicio systemd |
| `--repo` | repo oficial | URL git a clonar (útil para forks) |
| `--ref` | `main` | Rama, tag o commit a instalar |
| `--port` | `3000` | Puerto HTTP |
| `--domain` | *(vacío)* | `PUBLIC_BASE_URL`, ej. `https://share.tudominio.com` |
| `--max-file-size-mb` | `500` | Ídem `MAX_FILE_SIZE_MB` |
| `--max-ttl-minutes` | `1440` | Ídem `MAX_TTL_MINUTES` |
| `--default-ttl-minutes` | `120` | Ídem `DEFAULT_TTL_MINUTES` |
| `--rate-limit-max` | `20` | Ídem `RATE_LIMIT_MAX` |
| `--rate-limit-window-minutes` | `15` | Ídem `RATE_LIMIT_WINDOW_MINUTES` |
| `--no-start` | — | Instala y habilita el servicio, pero no lo arranca |

## Administrar el servicio

```bash
sudo systemctl status qrdrop
sudo systemctl restart qrdrop
sudo journalctl -u qrdrop -f
```

Para cambiar cualquier variable después de instalar, edita `/opt/qrdrop/.env`
y reinicia el servicio:

```bash
sudo nano /opt/qrdrop/.env
sudo systemctl restart qrdrop
```

## Exponerlo en internet con Cloudflare Tunnel

Se puede instalar y conectar el túnel en la misma corrida que instala
QRDrop, pasando el token de un tunnel ya creado en el dashboard de
Cloudflare (Zero Trust → Networks → Tunnels → Create a tunnel → copiar el
token; ahí mismo mapeá el **Public Hostname** a `http://localhost:3000`):

```bash
curl -fsSL https://raw.githubusercontent.com/gilberth/qrdrop/main/install/install.sh \
  | sudo bash -s -- --domain https://share.gytech.com.pe \
      --tunnel-token eyJhIjoi...
```

Esto instala el paquete `cloudflared` (repo oficial `pkg.cloudflare.com`) y
lo deja corriendo como servicio systemd, conectado a ese tunnel.

### Modo totalmente automático (sin tocar el dashboard)

Si preferís que el propio script cree el tunnel, la ruta de ingreso y el
registro DNS por API (necesita un [API Token](https://dash.cloudflare.com/profile/api-tokens)
con permisos de cuenta **Cloudflare Tunnel:Edit** y de zona **DNS:Edit**),
corré `install/cloudflare-tunnel.sh` aparte, antes o después de
`install.sh`:

```bash
curl -fsSL https://raw.githubusercontent.com/gilberth/qrdrop/main/install/cloudflare-tunnel.sh \
  | sudo bash -s -- --api-token cf_xxx --account-id 0123456789abcdef... \
      --zone gytech.com.pe --hostname share.gytech.com.pe
```

Es idempotente: si ya existe un tunnel con ese nombre (`--tunnel-name`,
default `qrdrop`) o un registro DNS para ese hostname, los actualiza en vez
de duplicarlos.

`install/cloudflare-tunnel.sh` también sirve para una instalación con
**Docker** en vez de systemd — detecta solo si hay un `docker-compose.yml`
en el directorio y usa `docker-compose.cloudflared.yml` como sidecar; ver la
sección correspondiente en el README principal del repo.

> Este modo automático hace cambios reales en tu cuenta de Cloudflare
> (crea un tunnel y un registro DNS). Si es la primera vez que lo corrés,
> probá primero con un `--hostname` de prueba antes de apuntarlo a tu
> dominio de producción.

## Desinstalar

```bash
curl -fsSL https://raw.githubusercontent.com/gilberth/qrdrop/main/install/uninstall.sh \
  | sudo bash -s -- --purge
```

Sin `--purge` solo se detiene y quita el servicio; el código y los archivos
en curso en `--dir`/`--data-dir` se conservan. Con `--purge` se borra todo,
incluida la carpeta de datos — úsalo solo si de verdad quieres perder los
archivos pendientes.

## Notas

- Pensado para distros basadas en Debian/Ubuntu (usa `apt-get`), que es lo
  que traen las plantillas de LXC más comunes en Proxmox.
- Al crear el LXC en Proxmox con una plantilla Debian 13 (systemd 257),
  Proxmox puede avisar `Systemd 257 detected. You may need to enable
  nesting.` — sin `nesting=1` en las features del contenedor, `systemctl`
  puede quedar en un estado degradado. Si te aparece ese warning, `pct set
  <vmid> --features nesting=1,keyctl=1` antes de correr el instalador.
- Si el LXC no arrancó con `systemd` como init (poco común, pero pasa en
  algunos contenedores minimalistas), el script deja el `.service` escrito
  y avisa que no pudo habilitarlo — en ese caso arranca la app a mano con
  `sudo -u qrdrop node /opt/qrdrop/server.js` o con tu propio supervisor.
- El paso que instala Node.js agrega el repositorio de NodeSource
  (`deb.nodesource.com`) al sistema — es el método estándar para tener una
  versión reciente de Node en Debian/Ubuntu, pero implica confiar en ese
  repositorio de terceros. Si ya tienes Node ≥ 20 instalado, este paso se
  salta por completo.
- Alternativa: si preferís aislar la app del sistema operativo del LXC, usá
  Docker Compose en su lugar — ver el README principal del repo.
