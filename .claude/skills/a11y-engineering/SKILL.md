---
name: a11y-engineering
description: Perform project-wide accessibility (a11y) engineering across Baudrate's Phoenix/LiveView web layer — auditing and fixing semantic HEEx and the ADR-0018 semantic id/class invariant, WAI-ARIA roles/states/names, keyboard operability and focus management (skip link, data-focus-target, FocusTrapHook, autocomplete comboboxes), forms, colour contrast across the Aqua default themes and user-selectable daisyUI themes, colour-not-alone signalling, reduced motion, live regions for PubSub-driven updates, accessible handling of federated/RSS content, and localized accessible names — then report findings by severity, apply fixes, and verify with the test suite.
---

Accessibility is a **hard project invariant, not polish**. `CLAUDE.md` marks it
**[TOP PRIORITY a11y]**: every meaningful element carries a stable, semantic `id`
and/or `class`, UI follows WAI-ARIA, and HTML5 semantic elements are used for
structure. [ADR-0018](../../../doc/adr/0018-semantic-ids-and-classes-for-accessibility.md)
records the *why*. This skill formalizes those commitments into a deep sweep so
Baudrate works for assistive technology, and so the LiveView and Wallaby tests
(which locate elements by those semantic anchors) keep passing.

Baudrate is a **public information hub** — guests, screen-reader users, and
keyboard-only users must be able to read boards, articles, and comments without an
account. A barrier on a public page shuts people out of public information, which
is the thing the project exists to provide.

This skill audits the **web layer** (`lib/baudrate_web/`): HEEx templates, function
components, LiveViews, the JS hooks in `assets/js/`, and `assets/css/app.css`. The
contexts under `lib/baudrate/` matter only indirectly (error copy, sanitized HTML
shape, remote `alt`/`name` text). For a broader review use `code-review` (it has a
quick a11y pass); this skill is the deep, project-wide accessibility sweep and fix.

Scope note: the app is **localized (en / zh_TW / ja_JP)**. An `aria-label` that is an
English literal is both an i18n bug and an a11y bug
([ADR-0019](../../../doc/adr/0019-gettext-i18n-no-bare-strings.md)).

---

## Step 1 — Orient

- Read `CLAUDE.md` (the **While Coding** a11y rules and Key Gotchas such as focus
  management), ADR-0018, ADR-0019, and the Layout System / LiveView JS Hooks sections
  of `doc/development.md`.
- Inventory the surfaces — every template and component:
  - **Root document**: `lib/baudrate_web/components/layouts/root.html.heex` — `<html lang>`
    derived from the locale, `<.live_title>` with the ` · <site_name>` suffix, the
    pre-hydration theme / font-size script, and the `#root-skip-link` targeting
    `#main-content`.
  - **App shell**: `lib/baudrate_web/components/layouts.ex` (`app/1` header/nav/main,
    `flash_group/1`, `theme_toggle/1`, unread DM / notification badges).
  - **Core components**: `lib/baudrate_web/components/core_components.ex` (`flash`,
    `button`, `input` + private `error`, `header`, `table`, `list`, `icon`, `avatar`,
    `pagination`, `report_modal`, `link_preview`), and
    `lib/baudrate_web/components/comment_components.ex` (the threaded comment tree).
  - **LiveViews**: `lib/baudrate_web/live/*_live.html.heex` (home, boards, articles
    new/edit/history, comments, feed, search, tags, bookmarks, DMs, notifications,
    profile, following, auth: login / register / TOTP / recovery codes / password
    reset, setup wizard) and `lib/baudrate_web/live/admin/*` (boards, bots, federation,
    invites, login attempts, moderation, moderation log, pending users, settings,
    users).
  - **Controller pages**: `controllers/page_html/`, `controllers/error_html/`.
  - **JS hooks** with a11y behaviour: `assets/js/app.js` (post-navigation focus via
    `data-focus-target`, dropdown focus handling), `focus_trap_hook.js`,
    `emoji_autocomplete.js`, `hashtag_autocomplete_hook.js`, `markdown_toolbar_hook.js`,
    `scroll_bottom_hook.js`, `avatar_crop_hook.js`, `copy_to_clipboard_hook.js`.
  - **Styles**: `assets/css/app.css` and the instance-default themes in
    `assets/css/themes/aquaosx.css` / `aquaosx-dark.css`.
- Toolchain: there is **no static a11y linter**. The gates are `mix precommit` and the
  test suite — ConnCase LiveView tests assert on semantic `id`/`class` anchors, and the
  Wallaby feature tests (`test/baudrate_web/features/`, `mix test --include feature`)
  drive a real Firefox. Reason through the criteria below manually.

---

## Step 2 — Semantic HEEx, landmarks & the ADR-0018 invariant  (the north star)

The goal: **every element locatable by role + accessible name**, no `<div>` soup, and
every meaningful element carrying a stable semantic `id`/`class`.

- **ADR-0018 coverage**: region/section containers, all interactive elements, every
  `:for` item (dynamic id from the record, e.g. `id={"comment-#{comment.id}"}`, plus a
  shared class), and key content nodes (headings, labels, values, empty states,
  error/preview blocks). Naming is kebab-case and page-prefixed with no BEM `__`.
  Changes are **non-destructive**: only add `id`/`class`, never remove or reorder
  utilities, `phx-*`, `aria-*`, `data-*`, `:if`/`:for`, or `gettext()`. Put the semantic
  class first. Check for duplicate ids on a page, especially where one component is
  rendered twice (e.g. a mobile and a desktop nav).
- **Landmarks**: one `<main id="main-content">` per page (the skip link depends on that
  id). Header, primary `<nav>`, and footer are provided by the shell. Pages must not add
  a second unlabelled landmark of the same type — several `<nav>`s (primary, breadcrumbs,
  pagination, admin sidebar) each need a distinct `aria-label`, like `pagination/1`'s
  `aria-label={gettext("Pagination")}`.
- **Headings**: one `<h1>` per page (`<.header>`), no skipped levels. Board pages,
  article pages, and the comment section are heading-structured. **User and remote
  content** (Markdown bodies, federated HTML, RSS articles) can contain their own
  `<h1>`–`<h6>`. Make sure those don't break the page outline, and that the article
  title stays the page's `<h1>`.
- **Page title** (WCAG 2.4.2): every route assigns a localized `page_title` (LiveView
  `mount`/`handle_params`, or before a controller `render/2`), usually matching its
  `<.header>`. `<.live_title>` appends the site-name suffix, so an untitled page reads as
  just the site name. Titles built from user content (article title, board name,
  username) should put the specific part first.
- **Sections and items**: headed content areas use `<section aria-labelledby=…>`,
  self-contained list items (article cards, feed items, comments, notifications, DMs)
  use `<article>`, supplementary panels use `<aside>`. Lists are `<ul>`/`<ol>`. The
  comment tree nests real lists so reply depth is exposed, not just indented.
- **Native elements over ARIA**: `<button>`, `<.link>`/`<a href>`, `<label>`, `<nav>`,
  `<dialog>` before `role=…` ("No ARIA is better than bad ARIA"). Remove redundant roles.
- **Interactive semantics**: anything clickable is a `<button>` or `<.link>`, never a
  `<div>`/`<span>` with `phx-click`. `<.link navigate/patch/href>` navigates,
  `<button phx-click>` acts. **Stretched-link cards** (`.card:has(> .card-body >
  .stretched-link)`) must keep one real link with a meaningful name, and must not nest
  other interactive controls inside the link's accessible name.
- **Time**: timestamps use `<time datetime="…">` with an ISO value and localized display
  text. Relative times ("3 min ago") keep the absolute time available.
- **Tables**: admin tables use `<.table>` (real `<th>` headers); icon-only row actions
  need names that include the row (`gettext("Ban %{name}", name: …)`), not a repeated
  bare "Ban".

---

## Step 3 — Accessible names, ARIA state & live regions  (localized)

- **Icon-only controls have names through `gettext()`**: the flash close button
  (`aria-label={gettext("close")}`) is the model. Audit `theme_toggle/1`, the font-size
  controls, like / boost / bookmark / share / report / forward buttons, the Markdown
  toolbar buttons, DM and notification bell badges, the pagination prev/next, and
  admin row actions. Counts belong in the name ("Notifications, 3 unread"), not only in
  a visual badge.
- **`<.icon>`** renders an empty `<span>` with a CSS mask, so it is decorative. When it is
  the only content of a control, the **control** carries the `aria-label`. Decorative
  emoji or glyphs next to text get `aria-hidden="true"`.
- **Toggle state**: like / boost / bookmark / follow / mute use `aria-pressed` (or a
  label that changes, e.g. "Unbookmark"), and the state must also be visible without
  colour. Expanders (collapsible comment threads, content-warning reveals, menus) use
  `aria-expanded` + `aria-controls`. The current nav item, page, and theme use
  `aria-current`. Disabled controls are truly `disabled`, not just styled.
- **Images and media**:
  - `avatar/1` uses the display name as `alt`. Next to a visible author name that
    repeats, so decorative avatars in bylines may prefer `alt=""`. Decide per context.
  - **Federated attachments** carry an AP `name` (alt text). Surface it as `alt`, and
    fall back to a localized generic label (not the filename or URL) when it's missing.
  - Media-proxy failures redirect to `/images/media-unavailable.svg`. The `alt` should
    still describe the intended content.
  - `link_preview` images use `gettext("Preview image for %{title}", …)`. The YouTube
    embed `<iframe>` needs a localized `title`.
  - RSS/bot and remote `body_html` images keep whatever `alt` the source sent. Never
    strip `alt` in sanitization (`native/baudrate_sanitizer`).
- **Content warnings / sensitive media**: remote `summary`/`sensitive` content hidden
  behind a reveal must use a real `<button aria-expanded>`, and the warning text must be
  readable before revealing.
- **Live regions**: async results must be announced.
  - `flash_group/1` handles flashes. Route save / delete / failure / validation results
    through flash or a scoped `aria-live` region.
  - PubSub-driven updates must not be silent: new comments on an article, incoming DMs
    in `conversation_live`, notification arrivals, and unread-count changes. Use
    `aria-live="polite"` on the region that grows, or announce a count summary. Never
    make the whole list live, which would re-read everything.
  - `scroll_bottom_hook.js` must not steal focus from a user reading or typing.
- **Accessibility tree check**: read each interactive element as *role + name* and
  confirm it is unambiguous out of visual context ("Reply" repeated 40 times in a
  comment tree needs the author or position in its name or description).

---

## Step 4 — Forms  (auth, 2FA, setup, articles, comments, polls, DMs, admin)

Prefer the `<.input>` core component. It wraps each control in a `<label>` and renders
`error/1`.

- Every input has a programmatic label. Placeholder text is **not** a label. Hand-written
  inputs (search box, DM composer, comment reply box, bot profile-field rows inside
  `phx-update="ignore"`) need `<label for>` or `aria-label` via `gettext()`.
- **Errors**: invalid fields carry `aria-invalid="true"` and `aria-describedby` pointing
  at the error node's id. Verify `input/1` does this for **every** type clause (text,
  checkbox, select, textarea), not just one. Error copy is localized through the
  `errors` domain (`translate_error/1`), tells the user how to fix it, and never leaks
  backend detail. Auth errors must not reveal account existence.
- **Groups**: poll options (radio / checkbox), board permission selects
  (`min_role_to_view` / `min_role_to_post`), article visibility, and board multi-select
  when posting use `<fieldset>` + `<legend>`.
- **Required** fields use `required` plus a visible indication that isn't colour-only.
- **2FA / WebAuthn**: TOTP inputs use `autocomplete="one-time-code"`,
  `inputmode="numeric"`, and a label. The QR code has a text alternative (the secret
  shown in a copyable form). WebAuthn prompts announce success and failure — a
  `NotAllowedError` must not fail silently. Recovery codes are a real list and the copy
  button announces "Copied".
- **Autocomplete comboboxes** (`emoji_autocomplete.js`, `hashtag_autocomplete_hook.js`,
  mention suggestions) follow the WAI-ARIA combobox pattern: input `role="combobox"`
  with `aria-expanded`, `aria-controls`, `aria-autocomplete="list"`, and
  `aria-activedescendant`; popup `role="listbox"` with `role="option"` items; Up/Down
  move, Enter/Tab select, Esc closes; the result count is announced.
- **Markdown toolbar / preview**: toolbar buttons are named, the toolbar is
  `role="toolbar"` with an `aria-label` if it groups many buttons, and the preview region
  (`aria-label={gettext("Markdown preview")}`) is not a focus trap.
- **Autosave** (`draft_save_hook.js`) announces "Draft saved" politely, not only as a
  silent icon change.
- Submit buttons are `type="submit"`, Enter submits, and nothing relies on pointer-only
  events. `phx-disable-with` text is localized.

---

## Step 5 — Keyboard operability & focus management

- **Everything reachable and operable by keyboard**: no positive `tabindex`, no traps
  except intentional modal traps, and every `phx-click` target is natively focusable.
- **Skip link**: `#root-skip-link` → `#main-content`. Confirm every layout that renders
  `<main>` uses that id, including the setup layout and error pages, and that the link
  becomes visible on focus under every theme.
- **Post-navigation focus**: `app.js` focuses the first interactive element inside
  `[data-focus-target]` after LiveView navigation. Per `CLAUDE.md`, add
  `data-focus-target` to the main container of list/browse pages, and **never** to form
  pages or pages with `autofocus`. Verify new list pages have it and form pages don't.
- **Dialogs**: `report_modal/1` and other `<dialog>`s use `FocusTrapHook`. Opening moves
  focus in, Esc closes, and closing **restores focus to the trigger**. Confirm the hook
  restores focus and that `show/2` / `hide/2` JS commands pair with it.
- **Dropdowns** (daisyUI focus-based menus, handled in `app.js` `focusin`/`focusout`):
  reachable by Tab, closable with Esc, and they don't close before a keyboard user can
  reach their items.
- **Destructive flows** (delete article / comment, ban, revoke, delete board): the
  confirmation is keyboard-operable, and focus lands somewhere meaningful afterwards,
  not on `<body>`.
- **Avatar cropper** (`avatar_crop_hook.js`, Cropper.js): offer a keyboard-operable
  path, or at least make sure upload without cropping works.
- **Visible focus** (2.4.7, and 2.4.11 for focus appearance): `app.css` replaces the
  link outline with `a:focus-visible { box-shadow: inset 0 0 0 1px var(--color-primary);
  outline: none; }`. A **1px** inset ring may not reach 3:1 against every theme's
  background. Check it under the Aqua pair and the high-risk themes (see Step 6), and
  make sure buttons/inputs keep daisyUI's focus ring. Never add `outline: none` without
  an equivalent replacement.
- Tab order follows visual order. Flex/grid `order` and absolute positioning must not
  desync DOM order from reading order.

---

## Step 6 — Colour, contrast, themes & motion

Baudrate ships the **Aqua (Mac OS X) pair** as the instance defaults
(`assets/css/themes/aquaosx.css`, `aquaosx-dark.css`). Admins can pick other defaults and
users can pick from **many built-in daisyUI themes** registered in `app.css`. Treat the
Aqua pair (and the `light`/`dark` fallbacks) as **must pass**. Built-in daisyUI themes
are upstream-owned. Report contrast failures there as Minor with the theme name rather
than retuning upstream palettes. Never introduce ad-hoc colours outside the theme tokens.

- **Contrast ≥ WCAG AA** (1.4.3 / 1.4.11): 4.5:1 for body text, 3:1 for large text and for
  UI component boundaries and focus indicators. Check the real token pairs
  (`--color-base-content` on `--color-base-100/200`, `-content` on `primary`/`secondary`/
  `accent`, `badge`, `alert`, disabled and placeholder text, link colour inside
  `prose`), not assumptions. The `theme-color` meta `#0ABAB5` is brand chrome, not a
  text pairing.
- **The `dark` custom variant** in `app.css` lists dark daisyUI themes by name. A newly
  registered dark theme missing from that list gets light-mode `dark:` utilities, which
  is a contrast bug. Keep the list in sync with the registered themes.
- **Never encode meaning in colour alone** (1.4.1): unread vs read notifications/DMs,
  pinned / locked / deleted articles, visibility (`public` / `unlisted` /
  `followers_only` / `direct`), follow state (pending / accepted / rejected), user role
  badges, moderation report status, login-attempt success/failure, federation on/off
  toggles, and form validity all need a text label or icon too, localized.
- **Reduced motion** (2.3.3): the stretched-card `transition: box-shadow 0.4s` in
  `app.css`, any `animate-*` utility (spinners, skeletons), smooth scrolling in
  `scroll_bottom_hook.js`, and topbar should respect `prefers-reduced-motion`. Prefer
  Tailwind `motion-safe:`/`motion-reduce:` or an `@media (prefers-reduced-motion:
  reduce)` block keyed on the semantic selector.
- **Forced colours / high contrast** (Windows): focus rings built only from `box-shadow`
  disappear in `forced-colors: active`. Pair them with a transparent `outline` so the
  system colour shows.
- **Zoom & text scaling** (1.4.4 / 1.4.10 / 1.4.12): the user font-size preference
  (75–150% on `<html>`) and 200% browser zoom must not clip text or cause horizontal
  scrolling at 320px width. Long federated tokens (URLs, handles) are the usual culprit.
  Apply the `minmax(0,1fr)` / `min-w-0` / `break-words` rules from `CLAUDE.md` Key Gotchas.

---

## Step 7 — Localized accessible names (i18n × a11y)

- **No bare literals** in any user-perceivable a11y attribute (`aria-label`,
  `aria-description`, `alt`, `title`, `<legend>`, `placeholder`, `phx-disable-with`,
  live-region and flash text, and strings set from JS hooks). Strings a hook injects
  ("Copied", "No results", "3 suggestions") must come from the server, e.g. via
  `data-*` attributes filled with `gettext()`. A hardcoded English string in
  `assets/js/` is invisible to zh_TW / ja_JP screen-reader users.
- Use `%{var}` interpolation, never string interpolation, so translators can reorder
  ("Reply to %{name}"). Shared helpers live in `BaudrateWeb.Helpers`. Reuse them so the
  accessible name matches the visible text.
- **Terminology** stays consistent with the visible UI: zh_TW Board = 看板 and User =
  使用者; ja_JP Board = 掲示板.
- `<html lang>` follows the active locale (`root.html.heex`). **Remote and RSS content**
  is often in another language. When the source declares one (AP `contentMap` /
  `language`, feed `xml:lang`), put `lang` on the content container so screen readers
  switch voice.
- **Locale parity**: every new msgid exists in `en`, `zh_TW`, and `ja_JP`. Run
  `mix gettext.extract --merge` and fill in the translations. An empty `msgstr` is an
  a11y gap for that locale.

---

## Step 8 — Verification

- Run the full suite with the project's seed and partitions:
  `for p in 1 2 3 4; do MIX_TEST_PARTITION=$p mix test --partitions 4 --seed 9527 & done; wait`.
  Keep ConnCase and Wallaby anchors intact, or update the tests in the same change.
- **Add tests** for fixes that can regress: `has_element?/2` assertions on `aria-label`,
  `aria-invalid`/`aria-describedby`, `aria-expanded`/`aria-pressed`, `<main
  id="main-content">`, and `page_title` per route. Tests mirror `lib/` structure.
- For browser-level checks (focus traps, skip link, focus restoration, combobox keys), use
  the Wallaby feature tests (`mix test --include feature`). Before trusting what the
  browser renders, clear stale digest artifacts from `priv/static/assets/` (see the
  `CLAUDE.md` Testing section).
- If heavier verification would help, **offer** (don't silently add) an `axe-core` pass
  over the key flows (home, board, article + comments, login/2FA, compose, DMs, admin)
  via the existing Wallaby/Selenium setup. Do not add a dependency without asking.

---

## Reporting

Group findings by severity:

| Severity | Criteria |
|----------|----------|
| **Critical** | Blocks a task for AT or keyboard users: unlabelled control on reading, auth/2FA, composing, or DM flows; keyboard trap; `phx-click` on a non-focusable element; form field with no accessible name; dialog that can't be closed by keyboard; skip link or `<main id="main-content">` missing; meaning conveyed by colour alone on a state users act on |
| **Major** | Real degradation: broken landmark/heading structure; contrast below AA in the Aqua pair or `light`/`dark` fallbacks; invisible focus; no focus restore after dialog or destructive action; error not linked to its field; silent PubSub update or async result; non-localized accessible name; combobox without the ARIA pattern; missing reduced-motion guard on a large animation; missing `page_title` |
| **Minor** | Hardening/polish: redundant ARIA; ADR-0018 id/class gaps on non-interactive content nodes; decorative image without `alt=""`; glyph not `aria-hidden`; missing `<time datetime>`; missing `lang` on foreign remote content; contrast failures in upstream daisyUI themes |

For each finding, cite **file:line**, name the WCAG 2.2 criterion (e.g. 1.3.1, 1.4.1,
2.4.3, 2.4.7, 4.1.2, 4.1.3), say who it breaks for (screen reader / keyboard only / low
vision / motor / cognitive) and how, and give a **concrete fix** (the exact HEEx,
attribute, or CSS change, `gettext()`-wrapped). If a category was audited and is clean,
**say so explicitly**. Silence is not a pass.

---

## Fixing

Fix all **Critical** and **Major** findings directly. Prefer the semantic-HTML or
core-component fix over an ARIA patch every time, and fix shared components
(`core_components.ex`, `comment_components.ex`, `layouts.ex`) before per-page
workarounds. CSS fixes target semantic selectors, never structural ones (ADR-0018).
Route every new user-facing string through `gettext()` in **all three** locales, then:

```bash
mix gettext.extract --merge   # sync en / zh_TW / ja_JP, then fill every new msgstr
mix precommit                 # compile --warnings-as-errors, format, test
```

The sweep isn't finished until the full partitioned suite passes, locales are in sync,
and the relevant docs (`doc/development.md`, `CLAUDE.md` Key Gotchas, ADR-0018 if an
invariant changes) are updated. a11y bugs cluster by pattern, so when you find one
(e.g. an unlabelled icon button), **sweep every component, LiveView, and JS hook for the
same class** before finishing.
