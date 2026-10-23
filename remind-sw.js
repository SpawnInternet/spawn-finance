/* Spawn Text service worker — shows push notifications (new texts) even when the app/browser is closed.
   Registered by remind.html only after the office turns alerts on (🔔). No caching: the page itself stays online-only. */
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));

self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (x) { d = { body: e.data && e.data.text() }; }
  const title = d.title || 'Spawn Text';
  e.waitUntil(self.registration.showNotification(title, {
    body: d.body || 'New text',
    tag: d.tag || 'spawn-text',
    renotify: true,
    icon: './remind-icon-192.png',
    badge: './remind-icon-192.png',
    data: { url: d.url || './remind.html#chats' },
  }));
});

self.addEventListener('notificationclick', e => {
  e.notification.close();
  const url = new URL(e.notification.data && e.notification.data.url || './remind.html#chats', self.location.href).href;
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(list => {
    for (const c of list) { if (c.url.split('#')[0] === url.split('#')[0] && 'focus' in c) { c.navigate(url); return c.focus(); } }
    return self.clients.openWindow(url);
  }));
});
