# 0017 — Tailwind + DaisyUI + esbuild, with no Node.js in the build

- **Status:** Accepted
- **Date:** Recorded retroactively 2026-08-09

## Context

Baudrate is server-rendered (ADR 0001), so the front end needs a stylesheet, a
small amount of JavaScript for LiveView hooks, and a theming story that a sysop
can change from the admin UI. What it does **not** need is a component
framework or a module graph.

The default Phoenix answer would still be `npm install`, which drags a Node
toolchain, a `node_modules` tree and a supply-chain surface into a release that
otherwise needs only Elixir, Rust and libvips.

## Decision

- **Tailwind CSS** via the `tailwind` Hex package, which downloads the
  standalone CLI binary. **DaisyUI** supplies components and themes.
- **esbuild** via the `esbuild` Hex package (standalone binary) bundles
  `assets/js`.
- **Heroicons** is vendored as a git dependency with `compile: false` and
  rendered through the `<.icon>` component — no icon font, no external request.
- **No `package.json`, no `node_modules`, no npm dependencies.** Client-side
  behaviour is a handful of LiveView JS hooks (`AvatarCropHook`,
  `DraftSaveHook`, `MarkdownToolbarHook`, `HashtagAutocompleteHook`,
  `PushManagerHook`, `ScrollBottomHook`) plus small vendored libraries where
  genuinely needed (e.g. Cropper.js for avatar cropping).
- Themes are DaisyUI themes injected per request by the `SetTheme` plug from
  admin-configured settings.
- Drafts autosave to `localStorage` via a generic hook — no server-side draft
  storage, no extra table.

## Consequences

- `mix assets.build` is the whole front-end build; CI and release builds need
  no Node.
- The supply chain is two vendored binaries and a git-pinned icon set rather
  than a transitive npm tree.
- Anything that genuinely needs a large JS library must be vendored
  deliberately, which is friction by design.
- Tailwind's content scanning means class names must appear literally in
  templates — dynamically constructed class strings get purged.
- CSP forbids third-party subresources (ADR 0006), so a CDN-hosted asset is not
  an option even as a shortcut.

## Alternatives considered

- **npm + Vite/webpack.** Rejected: large dependency and supply-chain surface
  for a server-rendered app with a few hooks.
- **Plain hand-written CSS.** Rejected: DaisyUI's themes are what make
  admin-configurable theming a setting rather than a project.
