import Cropper from "../vendor/cropperjs/cropper.esm.js"

const AvatarCropHook = {
  mounted() {
    this.cropper = null
    this.objectUrl = null

    this.previewImg = this.el.querySelector("[data-avatar-preview]")
    this.cropContainer = this.el.querySelector("[data-avatar-crop-container]")

    // Watch for file input additions to initialize crop preview
    const observer = new MutationObserver(() => {
      const fileInput = document.getElementById("avatar-file-input")
      if (fileInput && !fileInput._avatarBound) {
        fileInput._avatarBound = true
        fileInput.addEventListener("change", (e) => {
          const file = e.target.files && e.target.files[0]
          if (file) {
            this.objectUrl = URL.createObjectURL(file)
            this.pushEvent("show_crop_modal", {})
            // Wait for modal to render before initializing cropper
            setTimeout(() => this.initCrop(this.objectUrl), 100)
          }
        })
      }
    })
    observer.observe(document.body, { childList: true, subtree: true })
    this._observer = observer

    // Also check if input already exists
    const fileInput = document.getElementById("avatar-file-input")
    if (fileInput && !fileInput._avatarBound) {
      fileInput._avatarBound = true
      fileInput.addEventListener("change", (e) => {
        const file = e.target.files && e.target.files[0]
        if (file) {
          this.objectUrl = URL.createObjectURL(file)
          this.pushEvent("show_crop_modal", {})
          setTimeout(() => this.initCrop(this.objectUrl), 100)
        }
      })
    }

    // Listen for save-crop custom event from phx-click JS.dispatch
    this.el.addEventListener("avatar:save-crop", () => this.saveCrop())

    this.handleEvent("avatar_crop_reset", () => {
      this.reset()
    })
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
    }, { once: true })
  },

  saveCrop() {
    if (!this.cropper) return

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
