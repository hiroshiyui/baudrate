(() => {
  // js/service_worker.js
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
  self.addEventListener("notificationclick", (event) => {
    event.notification.close();
    const url = event.notification.data?.url || "/";
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
