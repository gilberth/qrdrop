# --- build: instala solo dependencias de produccion -------------------------
FROM node:22-alpine AS deps

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

# --- runtime ----------------------------------------------------------------
FROM node:22-alpine

ENV NODE_ENV=production \
    PORT=3000 \
    DATA_DIR=/data

# su-exec: para soltar privilegios de root a node en el entrypoint, una vez
# corregido el ownership de un volumen bind-mount montado desde el host.
RUN apk add --no-cache su-exec

WORKDIR /app

COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY server.js ./
COPY src ./src
COPY public ./public
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN mkdir -p /data \
    && chown -R node:node /data /app \
    && chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 3000
VOLUME ["/data"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget --quiet --spider "http://127.0.0.1:${PORT}/health" || exit 1

# El contenedor arranca como root: el entrypoint corrige el ownership de
# /data (un bind mount llega con el del host, no con el del build) y de ahi
# se ejecuta como node. El proceso de la app nunca corre como root.
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["node", "server.js"]
