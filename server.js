'use strict';

const crypto = require('crypto');
const fs = require('fs');
const fsp = require('fs/promises');
const path = require('path');

const express = require('express');
const helmet = require('helmet');
const multer = require('multer');
const rateLimit = require('express-rate-limit');
const QRCode = require('qrcode');

const config = require('./src/config');
const store = require('./src/store');
const cleanup = require('./src/cleanup');

const app = express();
const startedAt = Date.now();

// Detras de Cloudflare Tunnel / reverse proxy: sin esto req.protocol siempre
// diria "http" y el QR terminaria apuntando a una URL que el celular no resuelve.
app.set('trust proxy', 1);
app.disable('x-powered-by');

app.use(
  helmet({
    contentSecurityPolicy: {
      directives: {
        defaultSrc: ["'self'"],
        scriptSrc: ["'self'"],
        styleSrc: ["'self'"],
        // El QR viaja como data URL PNG generado en el servidor.
        imgSrc: ["'self'", 'data:'],
        connectSrc: ["'self'"],
        objectSrc: ["'none'"],
        frameAncestors: ["'none'"],
        baseUri: ["'self'"],
        formAction: ["'self'"],
        // Sin upgrade-insecure-requests: en LAN la app se sirve por http://
        // y forzar https romperia la carga de /app.css y /app.js.
        upgradeInsecureRequests: null,
      },
    },
    // Los archivos se sirven como descarga desde el mismo origen.
    crossOriginResourcePolicy: { policy: 'same-origin' },
  })
);

// --- almacenamiento temporal de subida -------------------------------------

const TMP_DIR = path.join(config.DATA_DIR, '.tmp');

const upload = multer({
  storage: multer.diskStorage({
    destination: (req, file, cb) => {
      // Recrea .tmp si algo externo lo borro; multer falla si no existe.
      fs.mkdir(TMP_DIR, { recursive: true }, (err) => cb(err, TMP_DIR));
    },
    // Nombre temporal aleatorio: el nombre real recien se aplica al mover.
    filename: (req, file, cb) => cb(null, crypto.randomBytes(12).toString('hex')),
  }),
  // Por defecto multer/busboy decodifican el nombre en latin1: sin esto un
  // "documento ñ.pdf" llega como "documento Ã±.pdf".
  defParamCharset: 'utf8',
  limits: {
    fileSize: config.MAX_FILE_SIZE_BYTES,
    files: 1,
    // Solo se espera el campo "file"; nada de payloads inflados.
    fields: 4,
  },
});

const uploadLimiter = rateLimit({
  windowMs: config.RATE_LIMIT_WINDOW_MINUTES * 60 * 1000,
  limit: config.RATE_LIMIT_MAX,
  standardHeaders: 'draft-7',
  legacyHeaders: false,
  message: { error: 'Demasiadas subidas desde esta IP. Intenta más tarde.' },
});

// --- helpers ----------------------------------------------------------------

/**
 * URL publica base para armar el link de descarga.
 * Prioridad: PUBLIC_BASE_URL > cabeceras X-Forwarded-* > Host del request.
 */
function publicBaseUrl(req) {
  if (config.PUBLIC_BASE_URL) return config.PUBLIC_BASE_URL;

  const forwardedHost = req.get('x-forwarded-host');
  const host = forwardedHost ? forwardedHost.split(',')[0].trim() : req.get('host');
  // req.protocol ya respeta X-Forwarded-Proto gracias a "trust proxy".
  return `${req.protocol}://${host}`;
}

/**
 * Content-Disposition con doble forma: ASCII para clientes viejos y
 * RFC 5987 (filename*) para nombres con acentos o no latinos.
 */
function contentDisposition(filename) {
  const ascii = filename.replace(/[^\x20-\x7e]/g, '_').replace(/"/g, '');
  return `attachment; filename="${ascii}"; filename*=UTF-8''${encodeURIComponent(filename)}`;
}

function sendNotFound(res, message) {
  res
    .status(404)
    .type('text/plain; charset=utf-8')
    .send(`${message}\n\nEl enlace ya no es válido. Los archivos de QRDrop se borran al descargarse o al expirar.\n`);
}

/** Borra un archivo temporal sin propagar errores. */
async function discardTemp(file) {
  if (!file || !file.path) return;
  await fsp.rm(file.path, { force: true }).catch(() => {});
}

// --- rutas ------------------------------------------------------------------

app.get('/health', (req, res) => {
  res.json({
    status: 'ok',
    uptime: Math.floor((Date.now() - startedAt) / 1000),
    activeFiles: store.activeCount(),
  });
});

// Limites del servidor, para que el frontend los muestre sin hardcodearlos.
app.get('/api/limits', (req, res) => {
  res.json({
    maxFileSizeMB: config.MAX_FILE_SIZE_MB,
    defaultTtlMinutes: config.DEFAULT_TTL_MINUTES,
    maxTtlMinutes: config.MAX_TTL_MINUTES,
  });
});

app.post('/api/upload', uploadLimiter, upload.single('file'), async (req, res, next) => {
  if (!req.file) {
    return res.status(400).json({ error: 'No se recibió ningún archivo.' });
  }

  try {
    // TTL en minutos por query param, acotado al maximo del servidor.
    let ttlMinutes = config.DEFAULT_TTL_MINUTES;
    if (req.query.ttl !== undefined && req.query.ttl !== '') {
      const requested = Number.parseInt(req.query.ttl, 10);
      if (!Number.isFinite(requested) || requested < 1) {
        await discardTemp(req.file);
        return res.status(400).json({ error: 'El parámetro ttl debe ser un número de minutos mayor a 0.' });
      }
      if (requested > config.MAX_TTL_MINUTES) {
        await discardTemp(req.file);
        return res
          .status(400)
          .json({ error: `El ttl máximo permitido es ${config.MAX_TTL_MINUTES} minutos.` });
      }
      ttlMinutes = requested;
    }

    const token = store.generateToken();
    const filename = store.sanitizeFilename(req.file.originalname);
    const dir = store.fileDir(token);

    await fsp.mkdir(dir, { recursive: true });
    // rename dentro del mismo volumen: no copia bytes.
    await fsp.rename(req.file.path, path.join(dir, filename));

    const record = await store.create({
      token,
      filename,
      size: req.file.size,
      mimetype: req.file.mimetype,
      ttlMinutes,
    });

    const downloadUrl = `${publicBaseUrl(req)}/d/${token}`;
    const qrDataUrl = await QRCode.toDataURL(downloadUrl, {
      width: 512,
      margin: 2,
      errorCorrectionLevel: 'M',
    });

    console.log(`[upload] ${filename} (${cleanup.formatBytes(record.size)}) token=${token} ttl=${ttlMinutes}min`);

    res.status(201).json({
      token,
      downloadUrl,
      expiresAt: record.expiresAt,
      filename: record.filename,
      size: record.size,
      qrDataUrl,
    });
  } catch (err) {
    await discardTemp(req.file);
    next(err);
  }
});

app.get('/d/:token', async (req, res, next) => {
  const { token } = req.params;
  const record = store.get(token);

  if (!record) {
    return sendNotFound(res, 'Archivo no encontrado.');
  }

  // Expirado o ya descargado: borra el archivo si aun quedaba, pero conserva el
  // registro para seguir respondiendo el motivo correcto hasta que lo barra el cron.
  if (!store.isDownloadable(record)) {
    await store.removeFiles(record).catch(() => {});
    return sendNotFound(res, record.downloaded ? 'Este archivo ya fue descargado.' : 'Este enlace expiró.');
  }

  const filePath = store.filePath(record);
  let stat;
  try {
    stat = await fsp.stat(filePath);
  } catch {
    // Registro sin archivo en disco: dato inconsistente, se descarta.
    await store.remove(token).catch(() => {});
    return sendNotFound(res, 'Archivo no encontrado.');
  }

  res.setHeader('Content-Type', record.mimetype);
  res.setHeader('Content-Length', stat.size);
  res.setHeader('Content-Disposition', contentDisposition(record.filename));
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('X-Content-Type-Options', 'nosniff');

  const stream = fs.createReadStream(filePath);

  stream.on('error', (err) => {
    console.error(`[download] error leyendo ${token}:`, err.message);
    if (!res.headersSent) return next(err);
    res.destroy();
  });

  // writableFinished solo es true si TODO el cuerpo salio al socket.
  // Si el cliente corta a mitad, el archivo se conserva para reintentar.
  res.on('close', () => {
    if (!res.writableFinished) {
      console.log(`[download] interrumpida token=${token}, archivo conservado`);
      stream.destroy();
      return;
    }

    (async () => {
      await store.markDownloaded(token);
      const freed = await store.removeFiles(record);
      console.log(`[download] ${record.filename} entregado, ${cleanup.formatBytes(freed)} liberado(s) token=${token}`);
    })().catch((err) => console.error(`[download] error limpiando ${token}:`, err.message));
  });

  stream.pipe(res);
});

// El frontend es lo unico estatico; /data nunca se expone.
app.use(express.static(path.join(__dirname, 'public'), { index: 'index.html', maxAge: '1h' }));

app.use((req, res) => {
  sendNotFound(res, 'Ruta no encontrada.');
});

// eslint-disable-next-line no-unused-vars -- Express identifica el handler de error por los 4 argumentos
app.use((err, req, res, next) => {
  if (err instanceof multer.MulterError) {
    const status = err.code === 'LIMIT_FILE_SIZE' ? 413 : 400;
    const message =
      err.code === 'LIMIT_FILE_SIZE'
        ? `El archivo supera el límite de ${config.MAX_FILE_SIZE_MB} MB.`
        : `Subida inválida (${err.code}).`;
    return res.status(status).json({ error: message });
  }

  console.error('[error]', err);
  if (res.headersSent) return res.destroy();
  res.status(500).json({ error: 'Error interno del servidor.' });
});

// --- arranque ---------------------------------------------------------------

async function main() {
  await fsp.mkdir(TMP_DIR, { recursive: true });
  await store.load();

  // Restos de un apagado abrupto: temporales sueltos y carpetas sin registro.
  await fsp.rm(TMP_DIR, { recursive: true, force: true });
  await fsp.mkdir(TMP_DIR, { recursive: true });
  await cleanup.sweep();
  await cleanup.sweepOrphans();
  cleanup.start();

  const server = app.listen(config.PORT, () => {
    console.log(`[qrdrop] escuchando en :${config.PORT}`);
    console.log(`[qrdrop] data=${config.DATA_DIR} maxFile=${config.MAX_FILE_SIZE_MB}MB ttl=${config.DEFAULT_TTL_MINUTES}min (max ${config.MAX_TTL_MINUTES})`);
    console.log(`[qrdrop] baseUrl=${config.PUBLIC_BASE_URL || '(derivada del request)'}`);
  });

  // Sin timeout de request: una subida de 500 MB por 4G puede tardar.
  server.requestTimeout = 0;
  server.headersTimeout = 60 * 1000;

  for (const signal of ['SIGTERM', 'SIGINT']) {
    process.on(signal, () => {
      console.log(`[qrdrop] ${signal} recibido, cerrando`);
      server.close(() => process.exit(0));
      // Si hay descargas colgadas, no esperamos indefinidamente.
      setTimeout(() => process.exit(0), 10_000).unref();
    });
  }
}

main().catch((err) => {
  console.error('[qrdrop] fallo al arrancar:', err);
  process.exit(1);
});
