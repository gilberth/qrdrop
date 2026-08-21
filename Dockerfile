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

WORKDIR /app

COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY server.js ./
COPY src ./src
COPY public ./public

# El volumen de datos pertenece al usuario no-root que corre el proceso.
RUN mkdir -p /data && chown -R node:node /data /app

USER node

EXPOSE 3000
VOLUME ["/data"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget --quiet --spider "http://127.0.0.1:${PORT}/health" || exit 1

CMD ["node", "server.js"]
