// LiveView hook for Web Push subscription management.
// Handles service worker registration, push permission, and subscription lifecycle.

function urlBase64ToUint8Array(base64String) {
  const padding = "=".repeat((4 - (base64String.length % 4)) % 4)
  const base64 = (base64String + padding).replace(/-/g, "+").replace(/_/g, "/")
  const rawData = atob(base64)
  const outputArray = new Uint8Array(rawData.length)
  for (let i = 0; i < rawData.length; ++i) {
    outputArray[i] = rawData.charCodeAt(i)
  }
  return outputArray
}

function arrayBufferToBase64Url(buffer) {
  const bytes = new Uint8Array(buffer)
  let binary = ""
  for (let i = 0; i < bytes.byteLength; i++) {
    binary += String.fromCharCode(bytes[i])
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

const PushManagerHook = {
  mounted() {
    this.vapidKey = document.querySelector('meta[name="vapid-public-key"]')?.content

    if (!this.vapidKey || !("serviceWorker" in navigator) || !("PushManager" in window)) {
      this.pushEvent("push_support", { supported: false, subscribed: false })
      return
    }

    navigator.serviceWorker
      .register("/service_worker.js", { scope: "/" })
      .then((registration) => {
        this.registration = registration
        return registration.pushManager.getSubscription()
      })
      .then((subscription) => {
        this.pushEvent("push_support", {
          supported: true,
          subscribed: !!subscription,
        })
      })
      .catch(() => {
        this.pushEvent("push_support", { supported: false, subscribed: false })
      })

    this.el.addEventListener("push:subscribe", () => this.subscribe())
    this.el.addEventListener("push:unsubscribe", () => this.unsubscribe())
  },

  subscribe() {
    if (!this.registration) return

    const applicationServerKey = urlBase64ToUint8Array(this.vapidKey)

    this.registration.pushManager
      .subscribe({ userVisibleOnly: true, applicationServerKey })
      .then((subscription) => {
        const key = subscription.getKey("p256dh")
        const auth = subscription.getKey("auth")
        const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content

        return fetch("/api/push-subscriptions", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "x-csrf-token": csrfToken,
          },
          body: JSON.stringify({
            endpoint: subscription.endpoint,
            p256dh: arrayBufferToBase64Url(key),
            auth: arrayBufferToBase64Url(auth),
            user_agent: navigator.userAgent,
          }),
        })
      })
      .then((response) => {
        if (response.ok) {
          this.pushEvent("push_subscribed", {})
        } else {
          this.pushEvent("push_subscribe_error", {})
        }
      })
      .catch((err) => {
        if (err.name === "NotAllowedError") {
          this.pushEvent("push_permission_denied", {})
        } else {
          this.pushEvent("push_subscribe_error", {})
        }
      })
  },

  unsubscribe() {
    if (!this.registration) return

    this.registration.pushManager
      .getSubscription()
      .then((subscription) => {
        if (!subscription) return

        const endpoint = subscription.endpoint
        const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content

        return subscription.unsubscribe().then(() => {
          return fetch("/api/push-subscriptions", {
            method: "DELETE",
            headers: {
              "Content-Type": "application/json",
              "x-csrf-token": csrfToken,
            },
            body: JSON.stringify({ endpoint }),
          })
        })
      })
      .then(() => {
        this.pushEvent("push_unsubscribed", {})
      })
      .catch(() => {
        this.pushEvent("push_unsubscribed", {})
      })
  },
}

export default PushManagerHook
