# Baudrate — Project TODOs

Audit date: 2026-02-25

---

## Security

- [ ] **Mass assignment: strip `pinned`/`locked` from article creation** — `Article.changeset/2` casts `:pinned`/`:locked`, allowing regular users to bypass moderator-only checks. Strip these from user params in `create_article`.
- [ ] **Add image ownership check in article edit** — `remove_image` event in `article_edit_live.ex:113-129` should verify `image.article_id == article.id` before deletion.
- [ ] **Password reset timing leak** — verify `reset_password_with_recovery_code` uses constant-time comparison for username lookup.
- [ ] **Tighten CSP** — remove `'unsafe-inline'` from `style-src` in `router.ex:64-66`.

## Test Coverage

- [ ] **HTTPClient redirect handling tests** — `federation/http_client.ex:40-83` has no tests for redirects (SSRF via redirect, loops, max redirects, missing Location header).
- [ ] **Permission boundary tests on soft-deleted/locked articles** — `can_edit_article?/2`, `can_delete_article?/2`, `can_pin_article?/2` on deleted/locked articles.
- [ ] **Rate limit error path test** — `rate_limit.ex:70-73` fails open on Hammer backend error, untested.
- [ ] **`update_dm_access/2` unit test** — tested indirectly via LiveView but no dedicated unit test.
- [ ] **Soft-delete idempotency tests** — double-delete should not error.

## Locale

- [ ] **Clean 28 stale gettext entries** — run `mix gettext.extract --merge` to remove msgids no longer in code.

## Code Quality

- [ ] **Extract pagination helper** — deduplicate ~160 lines across `search_articles/2`, `search_comments/2`, `articles_by_tag/2`, `list_feed_items/2`.
- [ ] **Split large modules** — `federation.ex` (1800 lines), `content.ex` (1729), `auth.ex` (1531), `inbox_handler.ex` (1127).
- [ ] **Refactor `following_collection/2`** — 3-level nested `case` in `federation.ex:609-698`, extract per-actor-type helpers.
- [ ] **Unify hidden filter functions** — `apply_hidden_filters/3` and `apply_search_hidden_filters/3` in `content.ex:1014-1053` are near-identical.
- [ ] **Fix function naming inconsistency** — `get_X_by_ap_id` returns nil (no `!`), `get_X_by_slug!` raises; `get_user/1` returns tuple, `get_user_by_username/1` returns nil.
- [ ] **Replace magic string `"accepted"`** — appears 10+ times in federation queries, should be a module attribute.

## Planned Features

_(No planned features at this time.)_
