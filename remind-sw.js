/* Spawn Text service worker — shows notifications for new texts, even when the app/browser is closed.
   Registered by remind.html only after the office turns alerts on (🔔). No caching: the page itself stays online-only.
   Each notification has ↩ Reply (opens that person's chat with the reply box ready) and Open chat.
   Typing the reply inside the notification itself is not possible for web apps in Chrome/Edge, so Reply opens the chat. */
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));

const ACTIONS = [{ action:'reply', title:'↩ Reply' }, { action:'open', title:'Open chat' }];
// the push tag is 'spawn-<mobile number>' (set by the database), so the number of the person comes from it
const numFromTag = t => { const m = /^spawn-(09\d{9})$/.exec(t || ''); return m ? m[1] : ''; };

self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (x) { d = { body: e.data && e.data.text() }; }
  const tag = d.tag || 'spawn-text', address = numFromTag(tag);
  e.waitUntil(self.registration.showNotification(d.title || 'Spawn Text', {
    body: d.body || 'New text',
    tag, renotify: true,
    icon: './remind-icon-192.png',
    badge: './remind-icon-192.png',
    actions: address ? ACTIONS : [],
    data: { url: d.url || './remind.html#chats', address },
  }));
});

self.addEventListener('notificationclick', e => {
  e.notification.close();
  const d = e.notification.data || {}, address = d.address || numFromTag(e.notification.tag);
  const reply = e.action === 'reply';
  const page = new URL('./remind.html', self.location.href).href;
  const url = address ? `${page}#chat=${address}${reply ? '&reply=1' : ''}` : new URL(d.url || './remind.html#chats', self.location.href).href;
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(list => {
    for (const c of list) {
      if (c.url.split('#')[0] === page && 'focus' in c) {
        // the open Spawn Text tab keeps its PIN session: tell it which chat to open instead of reloading it
        if (address) c.postMessage({ type: 'spawn-open-chat', address, reply });
        return c.focus();
      }
    }
    return self.clients.openWindow(url);
  }));
});
