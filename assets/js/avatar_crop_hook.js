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

// The editor: a fitted, fixed image under a movable, resizable square
// selection, with the outside shaded. The guide lines are decorative (the
// upstream template calls them `role="grid"`, with no rows or cells, so a
// screen reader would announce an empty grid). No `keyboard` attribute: Cropper.js
// binds it on the whole document, where Delete would remove the selection.
const CROP_TEMPLATE =
  '<cropper-canvas id="avatar-crop-canvas" class="avatar-crop-canvas" background>' +
  '<cropper-image initial-fit="contain"></cropper-image>' +
  "<cropper-shade></cropper-shade>" +
  '<cropper-selection aspect-ratio="1" movable resizable outlined hidden>' +
  '<cropper-grid aria-hidden="true" bordered covered></cropper-grid>' +
  '<cropper-crosshair aria-hidden="true" centered></cropper-crosshair>' +
  '<cropper-handle action="move" theme-color="rgba(255, 255, 255, 0.35)"></cropper-handle>' +
  '<cropper-handle action="ne-resize"></cropper-handle>' +
  '<cropper-handle action="nw-resize"></cropper-handle>' +
  '<cropper-handle action="se-resize"></cropper-handle>' +
  '<cropper-handle action="sw-resize"></cropper-handle>' +
  "</cropper-selection>" +
  "</cropper-canvas>"

// Selection coordinates are whole pixels and the image's box is not, so
// allow a pixel either way.
function withinBounds({ x, y, width, height }, bounds) {
  return (
    x >= bounds.x - 1 &&
    y >= bounds.y - 1 &&
    x + width <= bounds.x + bounds.width + 1 &&
    y + height <= bounds.y + bounds.height + 1
  )
}

// Resolves once the element's finite CSS animations and transitions (the
// dialog's opening) have run.
function settled(element) {
  if (!element || !element.getAnimations) return Promise.resolve()

  const running = element
    .getAnimations({ subtree: true })
    .filter((animation) => animation.effect?.getComputedTiming().endTime !== Infinity)
    .map((animation) => animation.finished.catch(() => {}))

  return Promise.all(running)
}

// Resolves once <cropper-image> has fitted its image to the canvas. Its own
// load listener does the fitting and was added first, so ours runs after it
// (`$ready()` can resolve before that, from a cached image).
function imageFitted(image) {
  if (image.$isReady) return Promise.resolve()
  return new Promise((resolve) => {
    image.$image.addEventListener("load", () => resolve(), { once: true })
  })
}

function clamp01(n) {
  return Math.min(Math.max(n, 0), 1)
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
    // Cropper.js 2 measures the page to fit the image, so it must start once
    // the dialog has finished opening: mid-animation it is scaled, and the
    // image would be fitted to the wrong box.
    settled(this.el.querySelector("dialog")).then(() => this.buildCropper(Cropper))
  },

  buildCropper(Cropper) {
    // The dialog may have been closed, or the page left, while it loaded.
    if (!this.previewImg || !this.previewImg.isConnected || this.cropper) return

    // The editor is built from web components. The image stays fitted and
    // still; the square selection moves and resizes over it.
    this.cropper = new Cropper(this.previewImg, { template: CROP_TEMPLATE })

    const image = this.cropper.getCropperImage()
    const selection = this.cropper.getCropperSelection()

    // Keep the selection on the image (what `viewMode: 1` did in 1.x).
    selection.addEventListener("change", (event) => {
      if (event.target !== selection) return
      const bounds = this.imageBounds()
      if (bounds && !withinBounds(event.detail, bounds)) event.preventDefault()
    })

    // Start from the largest centred square, as 1.x's `autoCropArea: 1` did.
    imageFitted(image).then(() => {
      const bounds = this.imageBounds()
      if (!bounds || this.cropper?.getCropperSelection() !== selection) return
      const size = Math.floor(Math.min(bounds.width, bounds.height))
      selection.$change(
        Math.ceil(bounds.x + (bounds.width - size) / 2),
        Math.ceil(bounds.y + (bounds.height - size) / 2),
        size,
        size,
      )
    })
  },

  // The image's box on the canvas, in the selection's coordinates.
  imageBounds() {
    const canvas = this.cropper?.getCropperCanvas()
    const image = this.cropper?.getCropperImage()
    if (!canvas || !image) return null

    const canvasRect = canvas.getBoundingClientRect()
    const imageRect = image.getBoundingClientRect()
    if (imageRect.width === 0 || imageRect.height === 0) return null

    return {
      x: imageRect.left - canvasRect.left,
      y: imageRect.top - canvasRect.top,
      width: imageRect.width,
      height: imageRect.height,
    }
  },

  saveCrop() {
    // The cropper is a separate script that may not have loaded (a dropped
    // connection, a blocked request). Save must still do something: with no
    // crop box the server takes the centred square, as it does for an avatar
    // chosen without cropping. A Save that silently did nothing left the
    // dialog open with no word of why.
    const selection = this.cropper?.getCropperSelection()
    const bounds = this.imageBounds()

    if (!selection || selection.hidden || !bounds || selection.width === 0) {
      this.pushEvent("save_crop", {})
      return
    }

    // The selection as fractions of the image, which is what the server
    // crops by; the image is only scaled and moved, so its on-screen box
    // maps linearly onto its natural size.
    const x = clamp01((selection.x - bounds.x) / bounds.width)
    const y = clamp01((selection.y - bounds.y) / bounds.height)

    const params = {
      x,
      y,
      width: Math.min(selection.width / bounds.width, 1 - x),
      height: Math.min(selection.height / bounds.height, 1 - y),
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
