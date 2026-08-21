'use strict';

const fsp = require('fs/promises');
const path = require('path');

const config = require('./config');
const store = require('./store');

function formatBytes(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  const units = ['KB', 'MB', 'GB', 'TB'];
  let value = bytes / 1024;
  let i = 0;
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024;
    i += 1;
  }
  return `${value.toFixed(1)} ${units[i]}`;
}

/**
 * Borra registros expirados y descargados fuera del periodo de gracia.
 * @returns {{removed: number, freed: number}}
 */
async function sweep() {
  const now = Date.now();
  let removed = 0;
  let freed = 0;

  for (const record of store.all()) {
    const expired = store.isExpired(record);
    const graceOver =
      record.downloaded &&
      record.downloadedAt &&
      now - Date.parse(record.downloadedAt) > config.DOWNLOADED_GRACE_MS;

    if (expired || graceOver) {
      freed += await store.remove(record.token);
      removed += 1;
    }
  }

  if (removed > 0) {
    console.log(`[cleanup] ${removed} archivo(s) eliminado(s), ${formatBytes(freed)} liberado(s)`);
  }
  return { removed, freed };
}

/**
 * Elimina carpetas de /data que ya no tienen registro en meta.json.
 * Cubre el caso de un crash entre mover el archivo y persistir la metadata.
 */
async function sweepOrphans() {
  let removed = 0;
  let entries;
  try {
    entries = await fsp.readdir(config.DATA_DIR, { withFileTypes: true });
  } catch {
    return { removed: 0 };
  }

  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    // .tmp guarda subidas en curso y no corresponde a ningun token.
    if (entry.name.startsWith('.')) continue;
    if (store.get(entry.name)) continue;

    await fsp.rm(path.join(config.DATA_DIR, entry.name), { recursive: true, force: true });
    removed += 1;
  }

  if (removed > 0) {
    console.log(`[cleanup] ${removed} carpeta(s) huerfana(s) eliminada(s)`);
  }
  return { removed };
}

/** Arranca el barrido periodico. Devuelve una funcion para detenerlo. */
function start() {
  const run = () => {
    sweep().catch((err) => console.error('[cleanup] error en barrido:', err.message));
  };

  const timer = setInterval(run, config.CLEANUP_INTERVAL_MS);
  // No mantiene vivo el proceso solo por el timer.
  if (typeof timer.unref === 'function') timer.unref();

  return () => clearInterval(timer);
}

module.exports = { start, sweep, sweepOrphans, formatBytes };
