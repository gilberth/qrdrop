#!/bin/sh
set -e

# El volumen /data llega con el ownership del host, no con el del build:
# el "chown node:node /data" de la imagen no sobrevive al bind mount. Se
# corrige aqui, en el arranque como root, antes de soltar privilegios.
if [ "$(id -u)" = "0" ]; then
  chown node:node "$DATA_DIR" 2>/dev/null || true
  exec su-exec node "$0" "$@"
fi

exec "$@"
