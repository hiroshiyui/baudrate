// Cropper.js as a bundle of its own (Phase 8D). It is 108 KB and only the
// avatar editor on /profile uses it, so it is no longer part of app.js:
// AvatarCropHook loads this file the first time a crop is needed.
import Cropper from "../vendor/cropperjs/cropper.esm.js"

window.BaudrateCropper = Cropper
