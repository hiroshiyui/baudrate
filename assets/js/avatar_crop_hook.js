// Cropper.js is a bundle of its own (assets/js/cropper_entry.js), loaded the
// first time a crop is needed rather than on every page (Phase 8D). The
// element carries its URL in `data-cropper-src`, rendered with `~p` so it is
// the digested name in production.
let cropperPromise = null

function loadCropper(src) {
  if (window.BaudrateCropper) return Promise.resolve(window.BaudrateCropper)

  if (!cropperPromise) {
    cropperPromise = new Promise((resolve, reject) => {
      const script = document.createElement("script")
      script.src = src
      script.onload = () => resolve(window.BaudrateCropper)
      script.onerror = () => {
        cropperPromise = null
        reject(new Error("could not load the image cropper"))
      }
      document.head.appendChild(script)
    })
  }

  return cropperPromise
}

const AvatarCropHook = {
  mounted() {
    this.cropper = null
    this.objectUrl = null
    this.pendingCrop = false

    this.previewImg = this.el.querySelector("[data-avatar-preview]")
    this.cropContainer = this.el.querySelector("[data-avatar-crop-container]")

    this._bindFileInput = (fileInput) => {
      if (fileInput && !fileInput._avatarBound) {
        fileInput._avatarBound = true
        fileInput.addEventListener("change", (e) => {
          const file = e.target.files && e.target.files[0]
          if (file) {
            this.objectUrl = URL.createObjectURL(file)
            this.pendingCrop = true
            // Start fetching the cropper while the dialog opens.
            loadCropper(this.el.dataset.cropperSrc).catch(() => {})
            this.pushEvent("show_crop_modal", {})
          }
        })
      }
    }

    // Watch for file input additions to initialize crop preview
    const observer = new MutationObserver(() => {
      const fileInput = document.querySelector("input[data-phx-hook='Phoenix.LiveFileUpload']")
      this._bindFileInput(fileInput)
    })
    observer.observe(document.body, { childList: true, subtree: true })
    this._observer = observer

    // Also check if input already exists
    const fileInput = document.querySelector("input[data-phx-hook='Phoenix.LiveFileUpload']")
    this._bindFileInput(fileInput)

    // Listen for open-picker custom event to trigger native file input click
    this.el.addEventListener("avatar:open-picker", () => {
      const input = document.querySelector("input[data-phx-hook='Phoenix.LiveFileUpload']")
      if (input) input.click()
    })

    // Listen for save-crop custom event from phx-click JS.dispatch
    this.el.addEventListener("avatar:save-crop", () => this.saveCrop())

    this.handleEvent("avatar_crop_reset", () => {
      this.reset()
    })
  },

  // Called after LiveView patches the DOM — safe to initialize CropperJS
  // because the dialog's `open` attribute is now present and rendered.
  updated() {
    if (this.pendingCrop && this.objectUrl) {
      const dialog = this.el.querySelector("dialog")
      if (dialog && dialog.hasAttribute("open")) {
        this.pendingCrop = false
        this.initCrop(this.objectUrl)
      }
    }
  },

  initCrop(url) {
    this.cleanupCropper()

    if (!this.previewImg) {
      this.previewImg = this.el.querySelector("[data-avatar-preview]")
    }
    if (!this.cropContainer) {
      this.cropContainer = this.el.querySelector("[data-avatar-crop-container]")
    }
    if (!this.previewImg) return

    this.previewImg.src = url
    if (this.cropContainer) {
      this.cropContainer.classList.remove("hidden")
    }

    this.previewImg.addEventListener("load", () => {
      loadCropper(this.el.dataset.cropperSrc)
        .then((Cropper) => this.startCropper(Cropper))
        .catch((error) => console.warn(error.message))
    }, { once: true })
  },

  startCropper(Cropper) {
    // The dialog may have been closed, or the page left, while it loaded.
    if (!this.previewImg || !this.previewImg.isConnected || this.cropper) return

    this.cropper = new Cropper(this.previewImg, {
      aspectRatio: 1,
      viewMode: 1,
      dragMode: "move",
      autoCropArea: 1,
      restore: false,
      guides: true,
      center: true,
      highlight: false,
      cropBoxMovable: true,
      cropBoxResizable: true,
      toggleDragModeOnDblclick: false,
    })
  },

  saveCrop() {
    // The cropper is a separate script that may not have loaded (a dropped
    // connection, a blocked request). Save must still do something: with no
    // crop box the server takes the centred square, as it does for an avatar
    // chosen without cropping. A Save that silently did nothing left the
    // dialog open with no word of why.
    if (!this.cropper) {
      this.pushEvent("save_crop", {})
      return
    }

    const imageData = this.cropper.getImageData()
    const cropData = this.cropper.getData(true)

    const params = {
      x: cropData.x / imageData.naturalWidth,
      y: cropData.y / imageData.naturalHeight,
      width: cropData.width / imageData.naturalWidth,
      height: cropData.height / imageData.naturalHeight,
    }

    this.pushEvent("save_crop", params)
  },

  reset() {
    this.pendingCrop = false
    this.cleanupCropper()
    if (this.objectUrl) {
      URL.revokeObjectURL(this.objectUrl)
      this.objectUrl = null
    }
    if (this.cropContainer) {
      this.cropContainer.classList.add("hidden")
    }
    if (this.previewImg) {
      this.previewImg.src = ""
    }
  },

  cleanupCropper() {
    if (this.cropper) {
      this.cropper.destroy()
      this.cropper = null
    }
  },

  destroyed() {
    this.cleanupCropper()
    if (this.objectUrl) {
      URL.revokeObjectURL(this.objectUrl)
      this.objectUrl = null
    }
    if (this._observer) {
      this._observer.disconnect()
    }
  },
}

export default AvatarCropHook
