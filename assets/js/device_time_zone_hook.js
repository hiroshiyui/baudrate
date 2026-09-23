/**
 * DeviceTimeZoneHook — sends the time zone this device is set to, when its
 * button is pressed, so a member does not have to find their zone in a list
 * of several hundred.
 *
 * Only on a click: the zone is a small fingerprint, and a page must not
 * report it just because someone opened it. The server checks the name
 * against the zones it knows and says so if it does not.
 */
const DeviceTimeZoneHook = {
  mounted() {
    this.handler = (e) => {
      e.preventDefault()

      let zone = null
      try {
        zone = Intl.DateTimeFormat().resolvedOptions().timeZone
      } catch (_) {
        zone = null
      }

      this.pushEvent("use_device_time_zone", {zone: zone || ""})
    }

    this.el.addEventListener("click", this.handler)
  },

  destroyed() {
    this.el.removeEventListener("click", this.handler)
  }
}

export default DeviceTimeZoneHook
