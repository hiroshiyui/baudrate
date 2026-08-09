# 0018 — Every meaningful element carries a semantic `id` / `class`

- **Status:** Accepted
- **Date:** Recorded retroactively 2026-08-09

## Context

A Tailwind/DaisyUI template is, by default, a wall of utility classes with no
stable handles. That has three costs, and they compound:

- **Assistive tooling and users** cannot be pointed at a specific element, and
  there is nothing stable to reference from ARIA attributes.
- **Tests** end up selecting by position or by text (`.card > div:nth-child(2)`),
  which breaks on any markup or translation change.
- **Custom CSS** ends up hooked onto structural selectors, so a refactor that
  adds a wrapper `div` silently changes the styling.

## Decision

**Every meaningful element in every page template carries a stable, semantic
`id` and/or `class`.** This is treated as a first-class accessibility
requirement, not optional polish.

- **Coverage** — region/section containers, all interactive elements (buttons,
  links, inputs, selects, textareas, toggles), every loop-rendered list/table/
  card item, and key content nodes (headings, labels, values, empty states,
  error/preview blocks). Skip purely presentational layout wrappers (bare
  `flex`/`grid`/spacer divs) and leaf presentational components (`<.icon>`).
- **Naming** — simple kebab-case, page/section-prefixed, no BEM `__`:
  `id="profile-bio-section"`, `class="profile-bio-label"`.
- **Uniqueness** — `id` unique per rendered page; `:for` items derive a dynamic
  id from the record (`id={"muted-user-#{mute.id}"}`) plus a shared stable
  class (`class="muted-user"`).
- **Non-destructive** — only *add* `id`/`class`; never remove or reorder
  existing Tailwind utilities, `phx-*`, `aria-*`, `data-*`, `:if`/`:for`, or
  `gettext()`. Semantic class first, utilities after.
- **Stylesheets target the semantic selectors.** Custom CSS in
  `assets/css/app.css` hooks onto these `id`/`class` selectors, never onto
  structural or positional selectors (`.card > .card-body`, `:nth-child`, tag
  chains). If the element a rule needs has no semantic handle, add one first.

This sits alongside the broader WAI-ARIA commitments: HTML5 semantic elements
(`<section aria-labelledby>`, `<article>`, `<aside>`, `<nav>`), a
skip-to-content link, `aria-live` on comment trees and flashes, `aria-invalid`
+ `aria-describedby` on invalid inputs, `aria-label` on icon-only buttons, and
`data-focus-target` for post-navigation focus management.

## Consequences

- Selectors in tests and CSS survive markup refactors.
- Each rule's intent is self-documenting from its selector.
- Cost: real discipline on every template change, and a bigger diff for new
  pages. The rule is stated in `CLAUDE.md` and `doc/development.md` precisely
  because it is the kind of thing that erodes silently.
- `data-focus-target` must **not** be added to form pages or pages with
  `autofocus`, or focus fights the browser.

## Alternatives considered

- **Add hooks only where a test or style needs one.** Rejected: produces
  inconsistent coverage and pushes the cost onto whoever writes the test later,
  and does nothing for assistive tooling.
- **`data-testid` attributes.** Rejected: solves only the testing third of the
  problem and adds a parallel naming scheme.
