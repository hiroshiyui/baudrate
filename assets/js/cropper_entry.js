// Cropper.js as a bundle of its own (Phase 8D). It is over 100 KB and only
// the avatar editor on /profile uses it, so it is no longer part of app.js:
// AvatarCropHook loads this file the first time a crop is needed. Loading it
// defines the <cropper-*> custom elements; their styles live in their shadow
// roots, so app.css carries none of them.
import Cropper from "../vendor/cropperjs/cropper.esm.js"

window.BaudrateCropper = Cropper
