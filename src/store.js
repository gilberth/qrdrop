'use strict';

const crypto = require('crypto');
const fs = require('fs');
const fsp = require('fs/promises');
const path = require('path');

const config = require('./config');

const META_FILE = path.join(config.DATA_DIR, 'meta.json');
const META_TMP = `${META_FILE}.tmp`;

/** @type {Map<string, object>} token -> registro de metadata */
const records = new Map();

// Las escrituras de meta.json se encadenan para que dos requests concurrentes
// no se pisen a mitad del rename.
let writeChain = Promise.resolve();

/**
 * Deja el nombre de archivo seguro para usarlo como componente de ruta.
 * Corta cualquier intento de path traversal y de nombres reservados.
 */
function sanitizeFilename(original) {
  const base = path.basename(String(original || ''))
    // separadores, control chars y caracteres problematicos en FS/headers
    .replace(/[\\/\x00-\x1f\x7f"]/g, '_')
    .replace(/^\.+/, '') // evita ".", "..", ".oculto" degenerando en ruta rara
    .trim();

  if (!base) return 'archivo';

  // Limita el largo conservando la extension.
  if (base.length > 180) {
    const ext = path.extname(base).slice(0, 20);
    return base.slice(0, 180 - ext.length) + ext;
  }
  return base;
}

/** Token aleatorio no adivinable: 18 bytes -> 24 chars base64url. */
function generateToken() {
  return crypto.randomBytes(18).toString('base64url');
}

function fileDir(token) {
  return path.join(config.DATA_DIR, token);
}

async function persist() {
  const snapshot = JSON.stringify(Object.fromEntries(records), null, 2);
  writeChain = writeChain.then(async () => {
    // tmp + rename para que meta.json nunca quede a medio escribir.
    await fsp.writeFile(META_TMP, snapshot, 'utf8');
    await fsp.rename(META_TMP, META_FILE);
  }).catch((err) => {
    console.error('[store] error persistiendo metadata:', err.message);
  });
  return writeChain;
}

/** Carga meta.json al arrancar. Un archivo corrupto o ausente arranca vacio. */
async function load() {
  await fsp.mkdir(config.DATA_DIR, { recursive: true });
  try {
    const raw = await fsp.readFile(META_FILE, 'utf8');
    const parsed = JSON.parse(raw);
    for (const [token, rec] of Object.entries(parsed)) {
      if (rec && typeof rec === 'object' && typeof rec.filename === 'string') {
        records.set(token, rec);
      }
    }
    console.log(`[store] ${records.size} registro(s) cargado(s) de meta.json`);
  } catch (err) {
    if (err.code !== 'ENOENT') {
      console.warn(`[store] meta.json ilegible (${err.message}), arrancando vacio`);
    }
  }
}

/**
 * Registra un archivo ya movido a su carpeta definitiva.
 * @returns {object} el registro creado
 */
async function create({ token, filename, size, mimetype, ttlMinutes }) {
  const now = Date.now();
  const record = {
    token,
    filename,
    size,
    mimetype: mimetype || 'application/octet-stream',
    createdAt: new Date(now).toISOString(),
    expiresAt: new Date(now + ttlMinutes * 60 * 1000).toISOString(),
    downloaded: false,
    downloadedAt: null,
  };
  records.set(token, record);
  await persist();
  return record;
}

function get(token) {
  return records.get(token);
}

function isExpired(record) {
  return Date.parse(record.expiresAt) <= Date.now();
}

/** Un registro sirve para descargar solo si no expiro y no fue descargado aun. */
function isDownloadable(record) {
  return Boolean(record) && !record.downloaded && !isExpired(record);
}

/** Ruta absoluta del archivo en disco. */
function filePath(record) {
  return path.join(fileDir(record.token), record.filename);
}

async function markDownloaded(token) {
  const record = records.get(token);
  if (!record) return;
  record.downloaded = true;
  record.downloadedAt = new Date().toISOString();
  await persist();
}

/**
 * Borra el archivo y su carpeta. No toca la metadata.
 * @returns {number} bytes liberados
 */
async function removeFiles(record) {
  let freed = 0;
  try {
    const stat = await fsp.stat(filePath(record));
    freed = stat.size;
  } catch {
    // Ya no estaba; seguimos igual con el rmdir por si quedo la carpeta vacia.
  }
  await fsp.rm(fileDir(record.token), { recursive: true, force: true });
  return freed;
}

/** Borra archivo + registro. */
async function remove(token) {
  const record = records.get(token);
  if (!record) return 0;
  const freed = await removeFiles(record);
  records.delete(token);
  await persist();
  return freed;
}

/** Cantidad de archivos aun descargables (para /health). */
function activeCount() {
  let n = 0;
  for (const record of records.values()) {
    if (isDownloadable(record)) n += 1;
  }
  return n;
}

function all() {
  return [...records.values()];
}

/** Solo para tests/limpieza: cuantos registros hay en total. */
function size() {
  return records.size;
}

module.exports = {
  load,
  create,
  get,
  remove,
  removeFiles,
  markDownloaded,
  isExpired,
  isDownloadable,
  filePath,
  fileDir,
  activeCount,
  all,
  size,
  sanitizeFilename,
  generateToken,
  META_FILE,
};
