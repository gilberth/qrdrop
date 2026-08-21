'use strict';

const path = require('path');

/**
 * Lee una variable de entorno numerica aplicando un default y un piso minimo.
 * Un valor invalido (no numerico, <= 0) cae al default en vez de reventar el arranque.
 */
function intEnv(name, fallback, { min = 1, max = Number.MAX_SAFE_INTEGER } = {}) {
  const raw = process.env[name];
  if (raw === undefined || raw === '') return fallback;

  const parsed = Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed) || parsed < min || parsed > max) {
    console.warn(`[config] ${name}="${raw}" invalido, usando ${fallback}`);
    return fallback;
  }
  return parsed;
}

const MAX_TTL_MINUTES = intEnv('MAX_TTL_MINUTES', 1440);
let DEFAULT_TTL_MINUTES = intEnv('DEFAULT_TTL_MINUTES', 120);

// El default nunca puede exceder el maximo permitido.
if (DEFAULT_TTL_MINUTES > MAX_TTL_MINUTES) {
  console.warn(
    `[config] DEFAULT_TTL_MINUTES (${DEFAULT_TTL_MINUTES}) > MAX_TTL_MINUTES (${MAX_TTL_MINUTES}), ajustando al maximo`
  );
  DEFAULT_TTL_MINUTES = MAX_TTL_MINUTES;
}

// PUBLIC_BASE_URL se normaliza sin barra final para concatenar rutas sin duplicarla.
const PUBLIC_BASE_URL = (process.env.PUBLIC_BASE_URL || '').trim().replace(/\/+$/, '');

const config = {
  PORT: intEnv('PORT', 3000, { max: 65535 }),
  DATA_DIR: path.resolve(process.env.DATA_DIR || '/data'),
  MAX_FILE_SIZE_MB: intEnv('MAX_FILE_SIZE_MB', 500),
  MAX_TTL_MINUTES,
  DEFAULT_TTL_MINUTES,
  PUBLIC_BASE_URL,
  RATE_LIMIT_MAX: intEnv('RATE_LIMIT_MAX', 20),
  RATE_LIMIT_WINDOW_MINUTES: intEnv('RATE_LIMIT_WINDOW_MINUTES', 15),

  // Cada cuanto corre el barrido de expirados.
  CLEANUP_INTERVAL_MS: 5 * 60 * 1000,
  // Gracia tras una descarga completada, para que el emisor alcance a ver la confirmacion.
  DOWNLOADED_GRACE_MS: 10 * 60 * 1000,
};

config.MAX_FILE_SIZE_BYTES = config.MAX_FILE_SIZE_MB * 1024 * 1024;

module.exports = config;
