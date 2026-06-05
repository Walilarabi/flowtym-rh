// Flowtym Portal — Service Worker
// Stratégie : network-first pour les navigations HTML, cache-first pour les assets statiques
const CACHE = 'flowtym-portal-v3'; // bumper à chaque déploiement qui change les routes

// Assets statiques à pré-cacher (non-HTML uniquement)
const PRECACHE = ['/sw.js'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(PRECACHE)));
  self.skipWaiting();
});

self.addEventListener('activate', e => {
  // Supprimer tous les anciens caches (y compris v1, v2 qui avaient le mauvais contenu)
  e.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k !== CACHE).map(k => {
        console.log('[SW] Suppression ancien cache:', k);
        return caches.delete(k);
      }))
    )
  );
  self.clients.claim();
});

self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET') return;
  const url = new URL(e.request.url);
  if (url.origin !== self.location.origin) return;

  const isNavigation = e.request.mode === 'navigate'
    || e.request.destination === 'document';

  if (isNavigation) {
    // Network-first pour les pages HTML — toujours le contenu à jour de Vercel
    e.respondWith(
      fetch(e.request).catch(() =>
        // Fallback offline : servir le portail si on est sur /salarie*
        url.pathname.startsWith('/salarie')
          ? caches.match('/portal.html')
          : caches.match('/index.html')
      )
    );
    return;
  }

  // Cache-first pour les assets statiques (JS, CSS, images…)
  e.respondWith(
    caches.match(e.request).then(cached => {
      const network = fetch(e.request).then(res => {
        if (res.ok && res.type === 'basic') {
          caches.open(CACHE).then(c => c.put(e.request, res.clone()));
        }
        return res;
      });
      return cached || network;
    })
  );
});

self.addEventListener('push', e => {
  if (!e.data) return;
  const data = e.data.json();
  e.waitUntil(
    self.registration.showNotification(data.title || 'Flowtym', {
      body: data.body || '',
      icon: '/portal.html',
      badge: '/portal.html',
      tag: data.tag || 'flowtym',
      data: { url: data.url || '/salarie' },
    })
  );
});

self.addEventListener('notificationclick', e => {
  e.notification.close();
  e.waitUntil(clients.openWindow(e.notification.data?.url || '/salarie'));
});
