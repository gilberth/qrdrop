#!/usr/bin/env bash
# Instala y conecta un Cloudflare Tunnel para exponer QRDrop en internet,
# tanto si corre con Docker Compose como si corre nativo (install.sh).
#
# Modo simple (token de un tunnel ya creado en el dashboard de Cloudflare
# Zero Trust -> Networks -> Tunnels -> Create a tunnel -> copiar el token,
# y ahi mismo mapear el Public Hostname a http://localhost:<PORT>):
#
#   curl -fsSL https://raw.githubusercontent.com/gilberth/qrdrop/main/install/cloudflare-tunnel.sh \
#     | sudo bash -s -- --token eyJhIjoi...
#
# Modo automatico (crea el tunnel, la ruta de ingreso y el registro DNS por
# API, sin tocar el dashboard; necesita un API Token con permisos de cuenta
# "Cloudflare Tunnel: Edit" y de zona "DNS: Edit"):
#
#   curl -fsSL https://raw.githubusercontent.com/gilberth/qrdrop/main/install/cloudflare-tunnel.sh \
#     | sudo bash -s -- --api-token cf_xxx --account-id 0123... \
#         --zone gytech.com.pe --hostname share.gytech.com.pe
#
# Detecta solo si correr como contenedor sidecar (docker-compose.cloudflared.yml,
# si --dir tiene un docker-compose.yml) o como servicio systemd nativo
# (paquete cloudflared de Cloudflare). Fuerza uno u otro con --docker / --native.
set -euo pipefail

API="https://api.cloudflare.com/client/v4"

MODE=""              # "token" o "api"
TOKEN=""
API_TOKEN=""
ACCOUNT_ID=""
ZONE=""
HOSTNAME_=""
TUNNEL_NAME="qrdrop"
SERVICE_URL=""
PORT="3000"
INSTALL_DIR="/opt/qrdrop"
DEPLOY=""             # "docker" o "native", autodetectado si se deja vacio

usage() {
  cat <<'EOF'
Uso: cloudflare-tunnel.sh (--token <tunnel-token> | --api-token <cf-api-token> --account-id <id> --zone <dominio> --hostname <fqdn>) [opciones]

Modo simple:
  --token <token>        Token de un tunnel ya creado en el dashboard de
                          Cloudflare (Zero Trust -> Networks -> Tunnels).
                          El Public Hostname debe estar mapeado ahi mismo.

Modo automatico (crea el tunnel y el registro DNS via API):
  --api-token <token>    API Token con permisos Account:"Cloudflare Tunnel:Edit"
                         y Zone:"DNS:Edit" sobre la zona indicada.
  --account-id <id>      ID de cuenta de Cloudflare.
  --zone <dominio>       Zona donde vive el hostname, ej. gytech.com.pe.
  --hostname <fqdn>      Hostname publico, ej. share.gytech.com.pe.
  --tunnel-name <n>      Nombre del tunnel a crear (default: qrdrop).

Comunes:
  --port <n>             Puerto local de QRDrop (default: 3000).
  --service-url <url>    Override completo del origen (default: http://localhost:<port>).
  --dir <ruta>           Instalacion de QRDrop a detectar (default: /opt/qrdrop,
                         o el directorio actual si tiene docker-compose.yml).
  --docker               Fuerza el modo contenedor (docker-compose.cloudflared.yml).
  --native               Fuerza el modo systemd nativo (paquete cloudflared).
  -h, --help             Muestra esta ayuda
EOF
}

log() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --token) MODE="token"; TOKEN="$2"; shift 2 ;;
    --api-token) MODE="api"; API_TOKEN="$2"; shift 2 ;;
    --account-id) ACCOUNT_ID="$2"; shift 2 ;;
    --zone) ZONE="$2"; shift 2 ;;
    --hostname) HOSTNAME_="$2"; shift 2 ;;
    --tunnel-name) TUNNEL_NAME="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --service-url) SERVICE_URL="$2"; shift 2 ;;
    --dir) INSTALL_DIR="$2"; shift 2 ;;
    --docker) DEPLOY="docker"; shift ;;
    --native) DEPLOY="native"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "opcion desconocida: $1 (usa --help)" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "este script necesita privilegios de root (usa sudo)."

case "$MODE" in
  token) [ -n "$TOKEN" ] || die "--token vacio." ;;
  api)
    [ -n "$API_TOKEN" ] && [ -n "$ACCOUNT_ID" ] && [ -n "$ZONE" ] && [ -n "$HOSTNAME_" ] \
      || die "modo --api-token necesita tambien --account-id, --zone y --hostname."
    ;;
  *) die "indica --token, o --api-token junto con --account-id, --zone y --hostname (usa --help)." ;;
esac

# --- helper para llamar a la API de Cloudflare y validar la respuesta -------
# cf_api <metodo> <path> [json-body]  -> deja el JSON de respuesta en $CF_OUT
cf_api() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-fsS -X "$method" "${API}${path}" \
    -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json")
  [ -n "$body" ] && args+=(--data "$body")
  CF_OUT="$(curl "${args[@]}")" \
    || die "la llamada a la API de Cloudflare fallo (curl): $method $path"
  if ! echo "$CF_OUT" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("success") else 1)' 2>/dev/null; then
    die "Cloudflare respondio con error en $method $path:
$CF_OUT"
  fi
}

cf_json_get() {
  # cf_json_get <expresion-python-sobre-CF_OUT> -- ej: data["result"]["id"]
  echo "$CF_OUT" | python3 -c "import json,sys; data=json.load(sys.stdin); print($1)"
}

# --- detectar si esto corre con Docker o nativo -----------------------------
# Se detecta antes del modo automatico porque el origen (SERVICE_URL) que se
# le declara a Cloudflare depende de esto: un cloudflared en su propio
# contenedor no puede llegar a qrdrop por "localhost", necesita el nombre del
# servicio de Compose en la red interna.
if [ -z "$DEPLOY" ]; then
  if [ -f "$INSTALL_DIR/docker-compose.yml" ] && command -v docker >/dev/null 2>&1 \
    && docker compose version >/dev/null 2>&1; then
    DEPLOY="docker"
  elif [ -f "./docker-compose.yml" ] && command -v docker >/dev/null 2>&1 \
    && docker compose version >/dev/null 2>&1; then
    DEPLOY="docker"
    INSTALL_DIR="$(pwd)"
  else
    DEPLOY="native"
  fi
fi
log "Modo de despliegue detectado: $DEPLOY"

if [ -z "$SERVICE_URL" ]; then
  if [ "$DEPLOY" = "docker" ]; then
    # "qrdrop" es el hostname del servicio en la red por defecto que crea
    # Compose; solo funciona si cloudflared se levanta con el mismo -f (ver
    # mas abajo), asi comparten esa red.
    SERVICE_URL="http://qrdrop:3000"
  else
    SERVICE_URL="http://localhost:${PORT}"
  fi
fi

# --- modo automatico: crear tunnel + ruta + DNS por API ---------------------
if [ "$MODE" = "api" ]; then
  command -v python3 >/dev/null 2>&1 || die "este modo necesita python3 (para parsear las respuestas JSON de la API)."

  log "Resolviendo zona ($ZONE)"
  if [[ "$ZONE" =~ ^[0-9a-f]{32}$ ]]; then
    ZONE_ID="$ZONE"
  else
    cf_api GET "/zones?name=${ZONE}"
    ZONE_ID="$(cf_json_get 'data["result"][0]["id"]')"
    [ -n "$ZONE_ID" ] && [ "$ZONE_ID" != "None" ] || die "no se encontro la zona '$ZONE' en esta cuenta de Cloudflare."
  fi
  echo "  zone_id: $ZONE_ID"

  log "Tunnel '$TUNNEL_NAME'"
  cf_api GET "/accounts/${ACCOUNT_ID}/cfd_tunnel?name=${TUNNEL_NAME}&is_deleted=false"
  TUNNEL_ID="$(cf_json_get 'data["result"][0]["id"] if data["result"] else ""')"
  if [ -n "$TUNNEL_ID" ]; then
    echo "  ya existe (id: $TUNNEL_ID), se reutiliza"
  else
    TUNNEL_SECRET="$(head -c32 /dev/urandom | base64)"
    cf_api POST "/accounts/${ACCOUNT_ID}/cfd_tunnel" \
      "{\"name\":\"${TUNNEL_NAME}\",\"config_src\":\"cloudflare\",\"tunnel_secret\":\"${TUNNEL_SECRET}\"}"
    TUNNEL_ID="$(cf_json_get 'data["result"]["id"]')"
    echo "  creado (id: $TUNNEL_ID)"
  fi

  log "Token de conexion"
  cf_api GET "/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/token"
  TOKEN="$(cf_json_get 'data["result"]')"
  [ -n "$TOKEN" ] || die "la API no devolvio un token de tunnel utilizable."

  log "Ruta de ingreso ($HOSTNAME_ -> $SERVICE_URL)"
  cf_api PUT "/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" \
    "{\"config\":{\"ingress\":[{\"hostname\":\"${HOSTNAME_}\",\"service\":\"${SERVICE_URL}\"},{\"service\":\"http_status:404\"}]}}"

  log "Registro DNS ($HOSTNAME_ CNAME ${TUNNEL_ID}.cfargotunnel.com)"
  cf_api GET "/zones/${ZONE_ID}/dns_records?type=CNAME&name=${HOSTNAME_}"
  RECORD_ID="$(cf_json_get 'data["result"][0]["id"] if data["result"] else ""')"
  DNS_BODY="{\"type\":\"CNAME\",\"name\":\"${HOSTNAME_}\",\"content\":\"${TUNNEL_ID}.cfargotunnel.com\",\"proxied\":true}"
  if [ -n "$RECORD_ID" ]; then
    cf_api PUT "/zones/${ZONE_ID}/dns_records/${RECORD_ID}" "$DNS_BODY"
    echo "  registro existente actualizado"
  else
    cf_api POST "/zones/${ZONE_ID}/dns_records" "$DNS_BODY"
    echo "  registro creado"
  fi
fi

if [ "$DEPLOY" = "docker" ]; then
  [ -f "$INSTALL_DIR/docker-compose.yml" ] || die "no se encontro docker-compose.yml en $INSTALL_DIR (usa --dir)."
  [ -f "$INSTALL_DIR/docker-compose.cloudflared.yml" ] \
    || die "falta docker-compose.cloudflared.yml en $INSTALL_DIR; actualiza el repo (git pull) e intenta de nuevo."

  ENV_FILE="$INSTALL_DIR/.env"
  touch "$ENV_FILE"
  if grep -q '^CLOUDFLARE_TUNNEL_TOKEN=' "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^CLOUDFLARE_TUNNEL_TOKEN=.*|CLOUDFLARE_TUNNEL_TOKEN=${TOKEN}|" "$ENV_FILE"
  else
    echo "CLOUDFLARE_TUNNEL_TOKEN=${TOKEN}" >> "$ENV_FILE"
  fi

  log "Levantando el contenedor cloudflared"
  ( cd "$INSTALL_DIR" && docker compose -f docker-compose.yml -f docker-compose.cloudflared.yml up -d cloudflared )
  echo "  Logs: docker compose -f docker-compose.yml -f docker-compose.cloudflared.yml logs -f cloudflared"

else
  command -v apt-get >/dev/null 2>&1 || die "el modo nativo necesita apt-get (Debian/Ubuntu)."

  if ! command -v cloudflared >/dev/null 2>&1; then
    log "Instalando el paquete cloudflared"
    mkdir -p --mode=0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o /usr/share/keyrings/cloudflare-main.gpg
    echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' \
      > /etc/apt/sources.list.d/cloudflared.list
    apt-get update -qq
    apt-get install -y cloudflared >/dev/null
  else
    echo "  cloudflared $(cloudflared --version 2>/dev/null | head -1 | awk '{print $3}') ya instalado"
  fi

  log "Servicio systemd de cloudflared"
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    # "cloudflared service install" crea y habilita su propio unit; si ya
    # existe uno de una corrida anterior, se reemplaza el token primero.
    systemctl stop cloudflared >/dev/null 2>&1 || true
    cloudflared service uninstall >/dev/null 2>&1 || true
    cloudflared service install "$TOKEN"
  else
    warn "systemd no esta activo en este entorno; no se pudo instalar el servicio."
    warn "Arranque manual: cloudflared tunnel run --token '$TOKEN'"
  fi
fi

log "Listo"
if [ -n "$HOSTNAME_" ]; then
  echo "  Hostname:  https://$HOSTNAME_  (la propagacion de DNS puede tardar unos segundos)"
fi
echo "  Origen local: $SERVICE_URL"
if [ "$MODE" = "token" ]; then
  echo "  Recorda que el Public Hostname de ese tunnel debe estar mapeado a $SERVICE_URL en el dashboard."
fi
