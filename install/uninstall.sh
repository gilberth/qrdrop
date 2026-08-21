#!/usr/bin/env bash
# Desinstala una instalacion de QRDrop hecha con install.sh.
#
#   curl -fsSL https://raw.githubusercontent.com/gilberth/qrdrop/main/install/uninstall.sh \
#     | sudo bash -s -- --purge
#
# Sin --purge solo detiene y quita el servicio; el codigo y los datos en
# INSTALL_DIR se conservan. Con --purge se borra todo, incluida la carpeta
# de datos: usalo solo si de verdad quieres perder los archivos pendientes.
set -euo pipefail

INSTALL_DIR="/opt/qrdrop"
SERVICE_NAME="qrdrop"
PURGE=0

usage() {
  cat <<'EOF'
Uso: uninstall.sh [opciones]

  --dir <ruta>     Carpeta de instalacion a remover (default: /opt/qrdrop)
  --name <nombre>  Nombre del servicio/usuario a remover (default: qrdrop)
  --purge          Ademas borra el codigo, la carpeta de datos y el usuario
  -h, --help       Muestra esta ayuda
EOF
}

die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) INSTALL_DIR="$2"; shift 2 ;;
    --name) SERVICE_NAME="$2"; shift 2 ;;
    --purge) PURGE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "opcion desconocida: $1 (usa --help)" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "este script necesita privilegios de root (usa sudo)."

if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl daemon-reload
fi
rm -f "/etc/systemd/system/${SERVICE_NAME}.service"

if [ "$PURGE" -eq 1 ]; then
  echo "--purge: borrando $INSTALL_DIR (incluida la carpeta de datos) y el usuario $SERVICE_NAME"
  rm -rf "$INSTALL_DIR"
  id -u "$SERVICE_NAME" >/dev/null 2>&1 && userdel "$SERVICE_NAME" >/dev/null 2>&1 || true
  echo "Listo: qrdrop y sus datos fueron eliminados por completo."
else
  echo "Servicio detenido y removido. El codigo y los datos siguen en $INSTALL_DIR."
  echo "Para borrar todo tambien: sudo $0 --dir '$INSTALL_DIR' --name '$SERVICE_NAME' --purge"
fi
