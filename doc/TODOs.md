# Baudrate — Project TODOs

Audit date: 2026-02-26

---

## Must Fix

- [x] **i18n:** Remove `fuzzy` flag from "Comment" entry in zh_TW and ja_JP after verification (`priv/gettext/{zh_TW,ja_JP}/LC_MESSAGES/default.po:3806`)
- [x] **a11y:** Add `scope="col"` to `<th>` elements in table component (`lib/baudrate_web/components/core_components.ex:430-458`) — affects all tables site-wide
- [x] **a11y:** Replaced all `text-base-content/50` with `text-base-content/70` across 24 files to meet WCAG 4.5:1 contrast ratio

## Should Fix

- [x] **code:** Replace `Repo.get!` with `Repo.get` + error handling in user-facing LiveView handlers (7 occurrences in `article_live.ex`, `admin/federation_live.ex`, `admin/moderation_live.ex`, `admin/invites_live.ex`)
- [x] **code:** Extract `can_moderate_article?/2` and `can_comment_on_article?/2` to `Content` context, replacing duplicated inline checks in `article_live.ex`
- [x] **a11y:** Remove misleading `aria-expanded="false"` from reply button (not a disclosure pattern — button hides when form shows)
- [x] **a11y:** Increase image remove button touch target to 44x44px, always visible on mobile (`article_new_live.html.heex`, `article_edit_live.html.heex`)

## Nice to Have

- [ ] **test:** Add edge case tests for board ancestor circular references and max depth
- [ ] **test:** Add pagination boundary tests (page=0, negative, empty results)
- [ ] **test:** Add federation delivery failure and retry tests
- [ ] **code:** Replace `for` with `Enum.each` for side-effect-only loops (`inbox_handler.ex:906`)
- [ ] **code:** Simplify deeply nested `cond`/`case`/`if` in `build_flag_report_attrs/3` (`inbox_handler.ex:1079-1126`)
- [ ] **code:** Add `@deprecated` annotation to `can_manage_article?/2` legacy alias in `content.ex`
- [ ] **security:** Document why CSP `style-src 'unsafe-inline'` is required (DaisyUI dependency) in `router.ex:50`
- [ ] **a11y:** Add visible `<label>` associations to auth form inputs (`login_live.html.heex`, `password_reset_live.html.heex`)
- [ ] **a11y:** Wrap file upload error messages with `role="alert"` (`article_new_live.html.heex:94-96`)
