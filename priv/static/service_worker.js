(() => {
  // js/service_worker.js
  function isSameOrigin(url) {
    try {
      const parsed = new URL(url, self.location.origin);
      return parsed.origin === self.location.origin;
    } catch {
      return false;
    }
  }
  self.addEventListener("push", (event) => {
    if (!event.data) return;
    let data;
    try {
      data = event.data.json();
    } catch {
      data = { title: "Baudrate", body: event.data.text() };
    }
    const options = {
      body: data.body || "",
      icon: data.icon || "/favicon.svg",
      badge: "/favicon.svg",
      data: { url: data.url || "/" },
      tag: data.type || "default",
      renotify: true
    };
    event.waitUntil(self.registration.showNotification(data.title || "Baudrate", options));
  });
  self.addEventListener("fetch", (event) => {
    event.respondWith(fetch(event.request));
  });
  self.addEventListener("notificationclick", (event) => {
    event.notification.close();
    const rawUrl = event.notification.data?.url;
    const url = rawUrl && isSameOrigin(rawUrl) ? rawUrl : "/";
    event.waitUntil(
      clients.matchAll({ type: "window", includeUncontrolled: true }).then((windowClients) => {
        for (const client of windowClients) {
          if (client.url === url && "focus" in client) {
            return client.focus();
          }
        }
        if (clients.openWindow) {
          return clients.openWindow(url);
        }
      })
    );
  });
})();
