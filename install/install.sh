#!/usr/bin/env bash
# Instalador de QRDrop sin Docker, pensado para un LXC/VM Debian o Ubuntu.
#
#   curl -fsSL https://raw.githubusercontent.com/gilberth/qrdrop/main/install/install.sh \
#     | sudo bash -s -- --domain https://share.gytech.com.pe
#
# Re-ejecutarlo actualiza una instalacion existente (git pull + npm ci +
# reinicio del servicio) en vez de romperla. Ver install/README.md para el
# detalle de cada flag.
set -euo pipefail

INSTALL_DIR="/opt/qrdrop"
DATA_DIR=""
SERVICE_NAME="qrdrop"
REPO_URL="https://github.com/gilberth/qrdrop.git"
REF="main"
NODE_MAJOR="22"
PORT="3000"
PUBLIC_BASE_URL=""
MAX_FILE_SIZE_MB="500"
MAX_TTL_MINUTES="1440"
DEFAULT_TTL_MINUTES="120"
RATE_LIMIT_MAX="20"
RATE_LIMIT_WINDOW_MINUTES="15"
START_SERVICE=1
TUNNEL_TOKEN=""

usage() {
  cat <<'EOF'
Uso: install.sh [opciones]

  --dir <ruta>              Carpeta de instalacion (default: /opt/qrdrop)
  --data-dir <ruta>         Carpeta de archivos subidos (default: <dir>/data)
  --name <nombre>           Nombre del servicio/usuario systemd (default: qrdrop)
  --repo <url>              Repositorio git a clonar (default: origen oficial)
  --ref <rama|tag>          Rama, tag o commit a instalar (default: main)
  --port <numero>           Puerto HTTP (default: 3000)
  --domain <url>            PUBLIC_BASE_URL, ej. https://share.tudominio.com
  --max-file-size-mb <n>    Default: 500
  --max-ttl-minutes <n>     Default: 1440
  --default-ttl-minutes <n> Default: 120
  --rate-limit-max <n>            Default: 20
  --rate-limit-window-minutes <n> Default: 15
  --tunnel-token <token>    Token de un Cloudflare Tunnel ya creado (Zero
                            Trust -> Networks -> Tunnels); tambien instala y
                            conecta cloudflared al terminar. Para crear el
                            tunnel por API en vez de pegar un token, usa
                            install/cloudflare-tunnel.sh --api-token en su
                            lugar (ver install/README.md).
  --no-start                Instala y habilita el servicio, pero no lo arranca
  -h, --help                Muestra esta ayuda

Volver a correr este mismo comando sobre una instalacion existente la
actualiza: hace git fetch + reset al ref indicado, reinstala dependencias y
reinicia el servicio. Los datos en curso (DATA_DIR) y el .env no se tocan.
EOF
}

log() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) INSTALL_DIR="$2"; shift 2 ;;
    --data-dir) DATA_DIR="$2"; shift 2 ;;
    --name) SERVICE_NAME="$2"; shift 2 ;;
    --repo) REPO_URL="$2"; shift 2 ;;
    --ref) REF="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --domain) PUBLIC_BASE_URL="$2"; shift 2 ;;
    --max-file-size-mb) MAX_FILE_SIZE_MB="$2"; shift 2 ;;
    --max-ttl-minutes) MAX_TTL_MINUTES="$2"; shift 2 ;;
    --default-ttl-minutes) DEFAULT_TTL_MINUTES="$2"; shift 2 ;;
    --rate-limit-max) RATE_LIMIT_MAX="$2"; shift 2 ;;
    --rate-limit-window-minutes) RATE_LIMIT_WINDOW_MINUTES="$2"; shift 2 ;;
    --tunnel-token) TUNNEL_TOKEN="$2"; shift 2 ;;
    --no-start) START_SERVICE=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "opcion desconocida: $1 (usa --help)" ;;
  esac
done

[ -n "$DATA_DIR" ] || DATA_DIR="$INSTALL_DIR/data"

[ "$(id -u)" -eq 0 ] || die "este instalador necesita privilegios de root (usa sudo)."
command -v apt-get >/dev/null 2>&1 || die "este instalador es para distros basadas en Debian/Ubuntu (falta apt-get)."

log "Paquetes base (git, ca-certificates, gnupg)"
apt-get update -qq
apt-get install -y --no-install-recommends git ca-certificates gnupg >/dev/null

log "Node.js >= ${NODE_MAJOR}"
install_node=1
if command -v node >/dev/null 2>&1; then
  current_major="$(node -e 'process.stdout.write(process.versions.node.split(".")[0])' 2>/dev/null || echo 0)"
  if [ "$current_major" -ge "$NODE_MAJOR" ] 2>/dev/null; then
    install_node=0
    echo "  node $(node -v) ya cumple el minimo"
  fi
fi
if [ "$install_node" -eq 1 ]; then
  echo "  instalando Node.js ${NODE_MAJOR}.x via NodeSource"
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - >/dev/null
  apt-get install -y nodejs >/dev/null
fi
NODE_BIN="$(command -v node)"

log "Usuario de servicio ($SERVICE_NAME)"
if ! id -u "$SERVICE_NAME" >/dev/null 2>&1; then
  useradd --system --home-dir "$INSTALL_DIR" --no-create-home --shell /usr/sbin/nologin "$SERVICE_NAME"
else
  echo "  ya existe, se reutiliza"
fi

log "Codigo fuente en $INSTALL_DIR"
# En una actualizacion, $INSTALL_DIR ya pertenece a $SERVICE_NAME (chown de
# la corrida anterior); git como root se niega a operar ahi ("dubious
# ownership") a menos que se declare explicitamente de confianza.
git config --global --add safe.directory "$INSTALL_DIR"
if [ -d "$INSTALL_DIR/.git" ]; then
  echo "  instalacion existente, actualizando a $REF"
  git -C "$INSTALL_DIR" fetch --depth 1 origin "$REF"
  git -C "$INSTALL_DIR" checkout -q --detach FETCH_HEAD
  git -C "$INSTALL_DIR" reset --hard -q FETCH_HEAD
  git -C "$INSTALL_DIR" clean -fdq
elif [ -e "$INSTALL_DIR" ] && [ -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
  die "$INSTALL_DIR ya existe y no es una instalacion de qrdrop (sin .git). Usa --dir para elegir otra ruta."
else
  git clone --branch "$REF" --depth 1 "$REPO_URL" "$INSTALL_DIR"
fi

log "Dependencias npm (produccion)"
chown -R "$SERVICE_NAME:$SERVICE_NAME" "$INSTALL_DIR"
# Entorno limpio para el usuario de servicio: "su" sin "-" hereda el entorno
# de root (proxies, NODE_EXTRA_CA_CERTS, etc.), y variables que ese usuario
# no puede leer hacen fallar a npm de forma silenciosa (exit 0 con error).
su -s /bin/bash "$SERVICE_NAME" -c \
  "cd '$INSTALL_DIR' && env -i HOME='$INSTALL_DIR' PATH='$PATH' npm ci --omit=dev"
[ -d "$INSTALL_DIR/node_modules/express" ] \
  || die "npm ci no genero node_modules correctamente; revisa el log de arriba."

log "Carpeta de datos ($DATA_DIR)"
mkdir -p "$DATA_DIR"
chown -R "$SERVICE_NAME:$SERVICE_NAME" "$DATA_DIR"

log "Archivo de entorno ($INSTALL_DIR/.env)"
ENV_FILE="$INSTALL_DIR/.env"
if [ -f "$ENV_FILE" ]; then
  # Una actualizacion no debe pisar valores que el operador ya haya
  # ajustado a mano (ej. MAX_FILE_SIZE_MB). Para regenerarlo desde cero,
  # hay que borrar el archivo antes de re-correr el instalador.
  echo "  ya existe, no se modifica (editalo a mano si necesitas cambiar algo)"
else
  cat > "$ENV_FILE" <<EOF
PORT=$PORT
DATA_DIR=$DATA_DIR
MAX_FILE_SIZE_MB=$MAX_FILE_SIZE_MB
MAX_TTL_MINUTES=$MAX_TTL_MINUTES
DEFAULT_TTL_MINUTES=$DEFAULT_TTL_MINUTES
PUBLIC_BASE_URL=$PUBLIC_BASE_URL
RATE_LIMIT_MAX=$RATE_LIMIT_MAX
RATE_LIMIT_WINDOW_MINUTES=$RATE_LIMIT_WINDOW_MINUTES
EOF
  chmod 600 "$ENV_FILE"
  chown "$SERVICE_NAME:$SERVICE_NAME" "$ENV_FILE"
fi

log "Servicio systemd ($SERVICE_NAME)"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
cat > "$UNIT_FILE" <<EOF
[Unit]
Description=QRDrop - transferencia de archivos via QR ($SERVICE_NAME)
After=network.target

[Service]
Type=simple
User=$SERVICE_NAME
Group=$SERVICE_NAME
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$NODE_BIN $INSTALL_DIR/server.js
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=$DATA_DIR

[Install]
WantedBy=multi-user.target
EOF

systemd_ok=0
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  systemd_ok=1
  systemctl daemon-reload
  if [ "$START_SERVICE" -eq 1 ]; then
    systemctl enable --now "$SERVICE_NAME"
  else
    systemctl enable "$SERVICE_NAME"
  fi
else
  warn "systemd no esta activo en este entorno; se escribio $UNIT_FILE pero no se pudo habilitar/arrancar."
  warn "Arranque manual: sudo -u $SERVICE_NAME $NODE_BIN $INSTALL_DIR/server.js"
fi

if [ "$systemd_ok" -eq 1 ] && [ "$START_SERVICE" -eq 1 ]; then
  log "Verificando arranque"
  ok=0
  for _ in 1 2 3 4 5; do
    if curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
      ok=1
      break
    fi
    sleep 1
  done
  [ "$ok" -eq 1 ] && echo "  /health responde correctamente" \
    || warn "el servicio no respondio en /health todavia; revisa: journalctl -u $SERVICE_NAME -e"
fi

if [ -n "$TUNNEL_TOKEN" ]; then
  log "Cloudflare Tunnel"
  "$INSTALL_DIR/install/cloudflare-tunnel.sh" --native --token "$TUNNEL_TOKEN" --port "$PORT"
fi

log "Listo"
echo "  Directorio:  $INSTALL_DIR"
echo "  Datos:       $DATA_DIR"
echo "  Config:      $ENV_FILE"
if [ "$systemd_ok" -eq 1 ]; then
  echo "  Servicio:    systemctl status $SERVICE_NAME"
  echo "  Logs:        journalctl -u $SERVICE_NAME -f"
fi
if [ -n "$PUBLIC_BASE_URL" ]; then
  echo "  URL publica: $PUBLIC_BASE_URL"
else
  echo "  URL local:   http://<ip-del-lxc>:$PORT  (usa --domain para el QR detras de un tunnel)"
fi
