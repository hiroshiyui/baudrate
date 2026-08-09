# 0019 — All user-visible text goes through Gettext

- **Status:** Accepted
- **Date:** Recorded retroactively 2026-08-09

## Context

Baudrate ships with English, Traditional Chinese (`zh_TW`) and Japanese
(`ja_JP`) locales and detects the visitor's language from `Accept-Language`.
Localization only works if it is total: one untranslated flash message, table
header or `title` attribute breaks the experience for every non-English reader,
and these leaks accumulate invisibly to an English-speaking developer.

The other failure mode is inconsistent terminology across a locale — the same
concept rendered three ways in three pages reads as three concepts.

## Decision

**Never write a bare English string for user-visible text.** Every such string
goes through `gettext()`. This covers flash messages, template text, feed
metadata, HTML attributes such as `title` and `aria-label`, error messages, and
anything else a user can read.

- Use `gettext()` interpolation (`%{var}`), never Elixir string interpolation
  into the msgid — an interpolated msgid cannot be extracted or translated.
- Shared translation helpers (`translate_role/1`, `translate_status/1`, …) live
  in `BaudrateWeb.Helpers`, so an enum value is rendered the same way
  everywhere.
- **Locales are kept in sync.** Adding a string means adding its translation in
  every locale in the same change, not later.
- Terminology is fixed per locale and must stay consistent:
  - `zh_TW`: Board = 看板 (not 版面 / 板塊), User = 使用者 (not 用戶)
  - `ja_JP`: Board = 掲示板 (not ボード); ダッシュボード for dashboard is correct

## Consequences

- Any locale can be added by translating the `.po` files, with no code changes.
- Every change that touches a template has a translation obligation; the
  documentation pass after each change explicitly checks for missing or
  incomplete translations.
- Dynamic strings must be designed as templates with named bindings, which
  occasionally forces a slightly less natural sentence structure in one
  language to keep the same msgid usable in all of them.

## Alternatives considered

- **English-only, translate later.** Rejected: retrofitting extraction across
  an entire template tree is far more work than doing it inline, and "later"
  never arrives.
- **Free-form terminology per page.** Rejected: inconsistent terms read as
  distinct features to the reader.
