# Baudrate — Project TODOs

Audit date: 2026-02-26

---

## Must Fix

- [ ] **i18n:** Remove `fuzzy` flag from "Comment" entry in zh_TW and ja_JP after verification (`priv/gettext/{zh_TW,ja_JP}/LC_MESSAGES/default.po:3806`)
- [ ] **a11y:** Add `scope="col"` to `<th>` elements in table component (`lib/baudrate_web/components/core_components.ex:430-458`) — affects all tables site-wide
- [ ] **a11y:** Audit `text-base-content/50` and `/70` classes against WCAG 4.5:1 contrast ratio requirement (footer, board, article, search templates)

## Should Fix

- [ ] **code:** Replace `Repo.get!` with `Repo.get` + error handling in user-facing LiveView handlers (~9 occurrences in `article_live.ex`, `admin/federation_live.ex`, `admin/moderation_live.ex`)
- [ ] **code:** Extract duplicated board-moderator authorization check in `article_live.ex:40-60` to a shared helper (repeated 3 times)
- [ ] **a11y:** Remove misleading `aria-expanded="false"` from reply button or implement proper disclosure pattern (`article_live.html.heex:82`)
- [ ] **a11y:** Increase image remove button touch target size for mobile (`article_new_live.html.heex:47-64`)

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
