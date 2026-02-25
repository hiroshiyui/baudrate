# Baudrate — Project TODOs

Audit date: 2026-02-25

---

## Security

- [x] **Mass assignment: strip `pinned`/`locked` from article creation** — removed `:pinned`/`:locked` from `Article.changeset/2` cast list. These fields are only set via `toggle_pin_article/1` and `toggle_lock_article/1`.
- [x] **Add image ownership check in article edit** — `remove_image` event verifies `image.article_id == article.id` before deletion.
- [x] **Password reset timing leak** — confirmed safe: `auth.ex:943` already uses `Bcrypt.no_user_verify()` for constant-time behavior. No action needed.
- [ ] **Tighten CSP** — remove `'unsafe-inline'` from `style-src` in `router.ex:64-66`. _Deferred: DaisyUI/LiveView require inline styles; removing breaks UI. Needs nonce-based CSP approach._

## Test Coverage

- [x] **HTTPClient redirect handling tests** — added 6 tests covering 301/302/307/308 redirects, too-many-redirects, missing Location header. Also fixed `get_redirect_location/2` bug (used `List.keyfind` on Req 0.5+ map headers).
- [x] **Permission boundary tests on soft-deleted/locked articles** — added 20 tests for `can_edit_article?/2`, `can_delete_article?/2`, `can_pin_article?/2`, `can_lock_article?/2` across admin/author/mod/other, including soft-deleted and locked articles.
- [x] **Rate limit error path test** — Added `BaudrateWeb.RateLimiter` behaviour + Hammer adapter + Mox mock. Error path (fail-open) now tested in all 3 rate limit modules.
- [x] **`update_dm_access/2` unit test** — added 4 tests: valid values ("anyone", "followers", "nobody") + invalid value returns error changeset, with persistence verification.
- [x] **Soft-delete idempotency tests** — added tests for double `soft_delete_article/1` and `soft_delete_comment/1`.

## Locale

- [x] **Clean stale gettext entries** — no obsolete msgids found; removed 52 spurious fuzzy flags from `en/default.po` (source locale, all had empty `msgstr`).

## Code Quality

- [x] **Replace magic follow state strings** — extracted `@state_accepted`/`@state_pending`/`@state_rejected` module attributes in `federation.ex`, `user_follow.ex`, and `board_follow.ex`.
- [x] **Unify hidden filter functions** — removed duplicate `apply_search_hidden_filters/3`; all call sites now use `apply_hidden_filters/3`.
- [x] **Refactor `following_collection/2`** — extracted `resolve_actor/1`, `user_following_collection/3`, and `board_following_collection/3` helpers to flatten nested cases.
- [x] **Extract pagination helper** — added `Baudrate.Content.Pagination` with `paginate_opts/2` and `paginate_query/3`; deduplicated `search_articles/2`, `search_comments/2`, and `articles_by_tag/2`. (`list_feed_items/2` excluded — uses merge-sort pagination from heterogeneous sources.)
- [ ] **Split large modules** — _deferred: high risk, needs incremental approach over multiple sessions._
- [ ] **Fix function naming inconsistency** — _deferred: analysis shows naming is mostly consistent; `get_user/1` uses tuples justifiably for multiple failure modes._

## Planned Features

_(No planned features at this time.)_
