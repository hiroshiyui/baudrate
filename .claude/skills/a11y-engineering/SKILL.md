---
name: a11y-engineering
description: Project-wide accessibility sweep of the web layer (HEEx, components, LiveViews, JS hooks, CSS) — semantic ids/classes (ADR 0018), ARIA, keyboard and focus, forms, contrast, live regions, localized names — then report by severity, fix, and verify.
---

Accessibility is a **hard invariant** ([TOP PRIORITY a11y] in `CLAUDE.md`, ADR 0018,
ADR 0019). Baudrate is a public information hub: a barrier on a public page shuts
people out of public information. Scope: `lib/baudrate_web/`, `assets/js/`,
`assets/css/` (contexts only for error copy, sanitized HTML shape, remote alt/name).
There is no a11y linter; the gates are the LiveView tests (semantic anchors) and the
Wallaby crawls. An English-literal `aria-label` is an i18n bug and an a11y bug.

## 1. Orient
Read `CLAUDE.md` (LiveView and templates, Project Conventions), ADR 0018/0019, and the
Layout System / LiveView JS Hooks sections of `doc/development.md`. Surfaces: `root.html.heex`
(`<html lang>`, `<.live_title>`, `#root-skip-link` → `#main-content`), `layouts.ex`,
`core_components.ex`, `comment_components.ex`, every `live/**/*.heex`, controller
pages, the hooks in `assets/js/`, `app.css` and the Aqua themes.

## 2. Semantics and ADR 0018
- Every region, interactive element, `:for` item (record-derived id + shared class)
  and key content node has a kebab-case, page-prefixed id/class. Only add; never
  remove utilities, `phx-*`, `aria-*`, `data-*`. No duplicate ids (mobile + desktop nav).
- One `<main id="main-content">`; several `<nav>`s each get a distinct `aria-label`.
- One `<h1>`, no skipped levels; user/remote HTML must not break the outline.
- Every route assigns a localized `page_title`, specific part first.
- `<section aria-labelledby>`, `<article>` for list items, `<aside>`, real `<ul>`/`<ol>`;
  the comment tree nests real lists.
- Native elements before ARIA; clickable things are `<button>` or `<.link>`, never
  `phx-click` on a `<div>`. Stretched-link cards keep one named link, nothing
  interactive inside its name.
- `<time datetime>` with localized text; admin tables use `<.table>`; row actions name
  their row ("Ban %{name}").

## 3. Names, state, live regions
- Icon-only controls get a `gettext()` name on the control (`<.icon>` is decorative);
  counts go in the name. Decorative glyphs `aria-hidden`.
- Toggles use `aria-pressed` or a changing label, visible without colour; expanders
  `aria-expanded` + `aria-controls`; `aria-current` for current page/nav/theme; truly
  `disabled`.
- Images: avatars `alt` per context (`""` beside a visible name); federated
  attachments use AP `name`, else a localized generic label; never strip `alt` in the
  sanitizer; YouTube iframe has a localized `title`.
- Content-warning reveals: real `<button aria-expanded>`/`<details>`, warning readable first.
- Async results through flash or a scoped `role="status"`; never `aria-live` on a whole
  list; PubSub arrivals (comments, DMs, notifications, unread counts) are announced;
  `scroll_bottom_hook.js` never steals focus.
- Read each control as role + name out of context ("Reply" ×40 needs the author).

## 4. Forms
- Prefer `<.input>`. Every hand-written input has `<label for>` or a `gettext`
  `aria-label`; a placeholder is not a label.
- Errors: `aria-invalid` + `aria-describedby` on **every** `input/1` type clause;
  localized, fixable copy; auth errors never reveal account existence.
- Radio/checkbox groups and board/visibility choices use `<fieldset>` + `<legend>`;
  required is visible without colour.
- TOTP: `autocomplete="one-time-code"`, `inputmode="numeric"`; the QR has a copyable
  secret; WebAuthn failures are announced; recovery codes are a list, copy says "Copied".
- Autocomplete (emoji, hashtag, mention) follows the WAI-ARIA combobox pattern
  (`role="combobox"`, `aria-expanded/controls/activedescendant`, listbox/options,
  arrow/Enter/Tab/Esc, count announced).
- Markdown toolbar `role="toolbar"` with named buttons; draft autosave announced
  politely; `phx-disable-with` localized.

## 5. Keyboard and focus
- No positive `tabindex`, no traps outside modals, every `phx-click` target focusable.
- Skip link works on every layout (setup, error pages) and is visible on focus.
- `data-focus-target` on list pages, never on forms or pages with `autofocus`.
- Dialogs: `FocusTrapHook`, Esc closes, focus returns to the trigger.
- Dropdowns reachable by Tab, closable by Esc. After a destructive action, focus lands
  somewhere meaningful (`push_event(socket, "focus", …)`), never `<body>`.
- Avatar upload works without the cropper.
- Visible focus ≥ 3:1 under the Aqua pair; never `outline: none` without a replacement;
  pair box-shadow rings with a transparent outline for `forced-colors`.
- DOM order = visual order.

## 6. Colour, themes, motion
- The Aqua pair and `light`/`dark` must pass AA (4.5:1 text; 3:1 large text, UI
  boundaries, focus); upstream daisyUI themes are reported as Minor. Theme tokens only.
- The `dark` custom variant in `app.css` lists every dark theme.
- Never colour alone: unread, pinned/locked/deleted, visibility, follow state, roles,
  report status, federation toggles, validity.
- `prefers-reduced-motion` for transitions, `animate-*`, smooth scrolling.
- 200% zoom and the 75–150% font setting: no clipping, no sideways scroll at 320 px
  (`minmax(0,1fr)`, `min-w-0`, `break-words`).

## 7. Localized names
No bare literals in `aria-*`, `alt`, `title`, `<legend>`, `placeholder`,
`phx-disable-with` or hook-injected text (hooks read `data-*` filled by `gettext`).
`%{var}` only. Settled terms (看板 / 掲示板, 使用者). Put `lang` on remote content that
declares one. Every new msgid is translated in zh_TW and ja_JP.

## Report
- **Critical:** blocks a task for AT or keyboard users (unlabelled control on reading,
  auth, composing or DMs; keyboard trap; unfocusable `phx-click`; unnamed field;
  dialog not closable by keyboard; missing skip link or `main`; colour-only state).
- **Major:** broken landmarks/headings; Aqua or light/dark contrast below AA;
  invisible focus; no focus restore; unlinked error; silent async update;
  unlocalized name; combobox without the pattern; missing `page_title`.
- **Minor:** redundant ARIA, ADR 0018 gaps on static nodes, decorative image without
  `alt=""`, missing `<time>`/`lang`, upstream theme contrast.

Each finding: `file:line`, WCAG 2.2 criterion, who it breaks for, the exact fix.
Say explicitly which areas were clean.

## Fix and verify
Fix Critical and Major directly, shared components before per-page patches, semantic
HTML before ARIA, CSS on semantic selectors. `mix gettext.extract --merge` and translate;
full suite (seed 9527, 4 partitions); after JS/CSS changes clear stale digests and run
`js_errors_test.exs` and `layout_test.exs` with `--include feature`. Add regression
assertions (`has_element?` on the anchor/attribute). Update docs (and ADR 0018 if the
invariant changes). When one instance of a class is found, sweep for the rest. Offer,
don't add, an axe-core pass.
