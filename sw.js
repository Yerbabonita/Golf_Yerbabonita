var CACHE = 'yerbabonita-perfil-v8';
var FILES = ['./', './index.html', './manifest.webmanifest', './icon-180.png', './icon-512.png'];
// Imágenes opcionales: si existen se guardan para verlas sin señal en el campo; si no existen, no pasa nada.
var OPCIONALES = ['./mapa.webp'];
for (var n = 1; n <= 9; n++) OPCIONALES.push('./hoyo-' + n + '.webp');

self.addEventListener('install', function (e) {
  e.waitUntil(caches.open(CACHE).then(function (c) {
    // 'reload' salta la caché del navegador: se guarda siempre la versión más nueva
    return c.addAll(FILES.map(function (u) { return new Request(u, { cache: 'reload' }); })).then(function () {
      return Promise.all(OPCIONALES.map(function (u) { return c.add(new Request(u, { cache: 'reload' })).catch(function () {}); }));
    });
  }).then(function () { return self.skipWaiting(); }));
});

self.addEventListener('activate', function (e) {
  e.waitUntil(caches.keys().then(function (keys) {
    return Promise.all(keys.map(function (k) { return k === CACHE ? null : caches.delete(k); }));
  }).then(function () { return self.clients.claim(); }));
});

// La página, el manifiesto, el mapa y las imágenes de los hoyos: primero internet (así siempre ves la última versión).
// Si no hay señal, o tarda más de 3,5 s, se abre la copia guardada.
function networkFirst(req) {
  var net = fetch(req.url, { cache: 'no-store' }).then(function (res) {
    if (res && res.ok) {                                   // solo se guardan respuestas correctas
      var copy = res.clone();
      caches.open(CACHE).then(function (c) { c.put(req, copy); });
    }
    return res;
  });
  var cached = caches.match(req).then(function (h) { return h || (req.mode === 'navigate' ? caches.match('./index.html') : undefined); });
  var slow = new Promise(function (resolve) {
    setTimeout(function () { cached.then(function (h) { if (h) resolve(h); }); }, 3500);
  });
  var safe = net.catch(function () {
    return cached.then(function (h) { if (h) return h; throw new Error('sin conexión'); });
  });
  return Promise.race([safe, slow]);
}

self.addEventListener('fetch', function (e) {
  var req = e.request;
  if (req.method !== 'GET') return;                       // los envíos a la base de datos no se tocan
  var url = new URL(req.url);
  if (url.origin !== location.origin) return;
  var page = req.mode === 'navigate' || /\/(index\.html)?$/.test(url.pathname) || /\.webmanifest$/.test(url.pathname) || /\/mapa\.[a-z]+$/i.test(url.pathname) || /\/hoyo-\d+\.[a-z]+$/i.test(url.pathname);
  if (page) { e.respondWith(networkFirst(req)); return; }
  // Íconos y demás: primero la copia guardada.
  e.respondWith(
    caches.match(req).then(function (hit) {
      if (hit) return hit;
      return fetch(req).then(function (res) {
        if (res && res.ok) {
          var copy = res.clone();
          caches.open(CACHE).then(function (c) { c.put(req, copy); });
        }
        return res;
      });
    })
  );
});
