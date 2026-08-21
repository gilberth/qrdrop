'use strict';

const $ = (id) => document.getElementById(id);

const views = {
  pick: $('view-pick'),
  progress: $('view-progress'),
  done: $('view-done'),
  error: $('view-error'),
};

let xhr = null;        // request de subida en curso
let expiryTimer = null; // intervalo del contador de expiracion

function show(name) {
  for (const [key, el] of Object.entries(views)) el.hidden = key !== name;
}

function formatBytes(bytes) {
  if (!Number.isFinite(bytes)) return '';
  if (bytes < 1024) return bytes + ' B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  let v = bytes / 1024;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i += 1; }
  return v.toFixed(v >= 10 || i === 0 ? 0 : 1) + ' ' + units[i];
}

/** "1h 58m" / "45m" / "menos de 1m" a partir de un ISO de expiracion. */
function formatRemaining(expiresAt) {
  const ms = Date.parse(expiresAt) - Date.now();
  if (ms <= 0) return 'expirado';

  const totalMin = Math.floor(ms / 60000);
  const h = Math.floor(totalMin / 60);
  const m = totalMin % 60;

  if (totalMin < 1) return 'expira en menos de 1m';
  if (h === 0) return `expira en ${m}m`;
  return `expira en ${h}h ${m}m`;
}

// --- limites (informativos; el servidor es quien valida de verdad) ---------

fetch('/api/limits')
  .then((r) => (r.ok ? r.json() : null))
  .then((cfg) => {
    if (!cfg) return;
    const ttl = cfg.defaultTtlMinutes;
    const ttlText = ttl >= 60 ? `${Math.round((ttl / 60) * 10) / 10} h` : `${ttl} min`;
    document.getElementById('limit').textContent =
      `Máximo ${cfg.maxFileSizeMB} MB · expira en ${ttlText}`;
  })
  .catch(() => {});

// --- seleccion de archivo ---------------------------------------------------

const drop = $('drop');
const input = $('input');

drop.addEventListener('click', () => input.click());
drop.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); input.click(); }
});

input.addEventListener('change', () => {
  if (input.files && input.files[0]) startUpload(input.files[0]);
});

for (const evt of ['dragenter', 'dragover']) {
  drop.addEventListener(evt, (e) => { e.preventDefault(); drop.classList.add('over'); });
}
for (const evt of ['dragleave', 'drop']) {
  drop.addEventListener(evt, (e) => { e.preventDefault(); drop.classList.remove('over'); });
}
drop.addEventListener('drop', (e) => {
  const file = e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files[0];
  if (file) startUpload(file);
});

// Evita que soltar el archivo fuera de la zona lo abra en la pestaña.
for (const evt of ['dragover', 'drop']) {
  window.addEventListener(evt, (e) => { if (e.target !== drop) e.preventDefault(); });
}

// --- subida -----------------------------------------------------------------

function startUpload(file) {
  $('up-name').textContent = file.name;
  $('up-size').textContent = formatBytes(file.size);
  $('bar').style.width = '0%';
  $('pct').textContent = '0%';
  show('progress');

  const form = new FormData();
  form.append('file', file);

  // XHR y no fetch: fetch no expone progreso de subida.
  xhr = new XMLHttpRequest();
  xhr.open('POST', '/api/upload');
  xhr.responseType = 'json';

  xhr.upload.addEventListener('progress', (e) => {
    if (!e.lengthComputable) return;
    const pct = Math.round((e.loaded / e.total) * 100);
    $('bar').style.width = pct + '%';
    $('pct').textContent = pct + '%';
  });

  xhr.onload = function onLoad() {
    const status = this.status;
    const body = this.response;
    xhr = null;

    if (status >= 200 && status < 300 && body && body.downloadUrl) {
      showResult(body);
    } else {
      showError((body && body.error) || `La subida falló (HTTP ${status}).`);
    }
  };

  xhr.onerror = () => { xhr = null; showError('No se pudo conectar con el servidor.'); };
  xhr.onabort = () => { xhr = null; reset(); };

  xhr.send(form);
}

$('cancel').addEventListener('click', () => { if (xhr) xhr.abort(); });

// --- resultado --------------------------------------------------------------

function showResult(data) {
  $('qr').src = data.qrDataUrl;
  $('done-name').textContent = data.filename;
  $('done-size').textContent = formatBytes(data.size);
  $('link').value = data.downloadUrl;

  const tick = () => { $('expiry').textContent = formatRemaining(data.expiresAt); };
  tick();
  clearInterval(expiryTimer);
  expiryTimer = setInterval(tick, 60000); // el contador se muestra en minutos

  show('done');
}

$('copy').addEventListener('click', async () => {
  const btn = $('copy');
  const value = $('link').value;
  try {
    await navigator.clipboard.writeText(value);
  } catch {
    // clipboard API requiere contexto seguro; en http:// se cae a execCommand.
    const el = $('link');
    el.select();
    el.setSelectionRange(0, 99999);
    document.execCommand('copy');
  }
  btn.textContent = 'Copiado';
  btn.classList.add('ok');
  setTimeout(() => { btn.textContent = 'Copiar'; btn.classList.remove('ok'); }, 1800);
});

// --- errores y reinicio -----------------------------------------------------

function showError(message) {
  $('err').textContent = message;
  show('error');
}

function reset() {
  clearInterval(expiryTimer);
  expiryTimer = null;
  input.value = '';
  show('pick');
}

$('again').addEventListener('click', reset);
$('retry').addEventListener('click', reset);
