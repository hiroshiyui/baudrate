# Baudrate — Project TODOs

---

## Feature Backlog

Identified via competitive analysis against Discourse, Lemmy, Flarum, NodeBB, and Misskey.

### Lower Priority — Engagement & Platform

- [ ] **infra:** Admin analytics dashboard — DAU/MAU, posts/day, response times, community health metrics
- [ ] **infra:** S3 / CDN object storage — external media storage for horizontal scaling (currently local filesystem only)

---

## Code Review Findings

Findings from project-wide code review (2026-03-01). Grouped by category.

---

### Security

- [ ] **sec-1:** Add `:rate_limit_mount` to `:authenticated` live_session — authenticated users bypass WebSocket mount rate limit (`router.ex:228`)
- [ ] **sec-2:** Add explicit `length:` option to `Plug.Parsers` — defaults to 8MB for non-AP browser requests (`endpoint.ex:77`)
- [ ] **sec-3:** Document `SECRET_KEY_BASE` rotation impact — rotating invalidates all encrypted TOTP secrets and federation private keys (`totp_vault.ex`, `key_vault.ex`)
- [ ] **sec-4:** Block IPv6 multicast range (`ff00::/8`) in SSRF `private_ip?/1` check (`http_client.ex:253`)

---

### Test Coverage — Missing Tests

- [ ] **test-1:** Add tests for `notify_local_article_liked/2` and `notify_local_comment_liked/2` (`notification_hooks_test.exs`)
- [ ] **test-2:** Add tests for `build_like_article/2`, `build_undo_like_article/2`, `publish_article_liked/2`, `publish_article_unliked/2` (`publisher_test.exs`)
- [ ] **test-3:** Add tests for `toggle_comment_bookmark/2` and `comment_bookmarked?/2` (`content_test.exs`)
- [ ] **test-4:** Add tests for `can_comment_on_article?/2` and `can_moderate_article?/2` (`content_test.exs`)
- [ ] **test-5:** Add unit tests for `update_remote_poll_counts/2`, `recalc_poll_counts/1`, `create_remote_poll_vote/1` (`content_test.exs`)
- [ ] **test-6:** Add test for `unread_counts_for_conversations/2` (`messaging_test.exs`)
- [ ] **test-7:** Add test for `publish_key_rotation/2` (`publisher_test.exs`)
- [ ] **test-8:** Add unit test for `delete_article_like_by_ap_id/2` (2-arity, remote_actor_id guard) (`content_test.exs`)

### Test Coverage — Anti-Patterns

- [ ] **test-9:** Replace `Process.sleep(1100)` with `Repo.update_all` timestamp backdating for ordering test (`messaging_test.exs:293`)
- [ ] **test-10:** Move delivery hooks test to separate `async: false` module — shared sandbox in async test is dangerous (`content_test.exs:524-575`)
- [ ] **test-11:** Remove unnecessary `Process.sleep(50)` in publisher tests — synchronous with `federation_async: false` (`publisher_test.exs:52,306,331,373`)
- [ ] **test-12:** Replace broad `length(jobs) >= 1` assertions with exact count + inbox URL checks (`publisher_test.exs:430,447,477,494`)

---

### i18n — Terminology Consistency

- [x] **i18n-1:** zh_TW: Standardize "Board" to 看板 — currently uses 看板 (31), 版面 (18), 板塊 (4)
- [x] **i18n-2:** zh_TW: Standardize "User" to 使用者 — currently uses 使用者 (60), 用戶 (16)
- [x] **i18n-3:** ja_JP: Standardize "Board" to 掲示板 — currently uses 掲示板 (35), ボード (11)

---

### Documentation

- [x] **doc-1:** Remove stale `TOTP_VAULT_KEY` env var from README — TOTP key is derived from `SECRET_KEY_BASE` (`README.md:73`)
- [x] **doc-2:** Fix or replace `AGENTS.md` — contradicts CLAUDE.md (layout wrapping, DaisyUI, `current_scope`)
- [x] **doc-3:** Fix CSP `img-src` description conflict — `development.md:991` says "allows https:" but `sysop.md:581` (correct) says "restricted to self/data/blob"
- [x] **doc-4:** Add "Notifications" section to `development.md` — complete notification system is undocumented
- [x] **doc-5:** Add "Bookmarks" section to `development.md` — feature fully implemented but undocumented
- [x] **doc-6:** Add `bookmarks_live.ex` and `board_follows_live.ex` to project structure table in `development.md`
- [x] **doc-7:** Add `/ap/users/:username/following` and `/ap/boards/:slug/following` endpoints to `doc/api.md`
- [x] **doc-8:** Update CLAUDE.md auth hooks list — missing `:optional_auth`, `:require_password_auth`, `:redirect_if_authenticated`, `:rate_limit_mount`
- [x] **doc-9:** Remove stale phase labels ("Phase 1 — backend only, UI in Phase 2") from `development.md:849` and `federation.ex` @moduledoc
- [x] **doc-10:** Add `@doc` to undocumented public functions: `decrypt_totp_secret/1`, `verify_password/2` (`auth.ex`), `validate_invite_code/1` (`auth.ex`), `get_message_by_ap_id/1` (`messaging.ex`), changeset functions in `invite_code.ex`
- [ ] **doc-11:** Improve `@spec` coverage across context modules — ~85 missing in `content.ex`, ~48 in `auth.ex`, ~60 in `federation.ex`, 31 in `publisher.ex`

---

### Code Smells — Duplicated Code

- [ ] **smell-1:** Extract `user_can_view_article?/2` to `Content` — duplicated in `article_live.ex:776` and `article_history_live.ex:64`
- [ ] **smell-2:** Unify `has_unique_constraint_error?` — triplicated in `content.ex:1912`, `notification.ex:296`, `inbox_handler.ex:1061`
- [ ] **smell-3:** Extract `Content.batch_comment_counts/1` — duplicated batch comment count query in `content.ex:308` and `federation.ex:1477`
- [ ] **smell-4:** Extract private `do_toggle_like/4` — `toggle_article_like` and `toggle_comment_like` have near-identical structure (`content.ex:1628,1727`)
- [ ] **smell-5:** Extract private `not_found(conn)` helper — 404 JSON response repeated 12 times in `activity_pub_controller.ex`
- [ ] **smell-6:** Extract shared `with_rate_limit_or_admin/3` — admin rate-limit bypass pattern repeated in 3 handlers in `article_live.ex`

### Code Smells — Large Modules

- [ ] **smell-7:** Split `content.ex` (2,840 lines) — consider: Articles, Comments, Boards, Polls, Search, Likes, Bookmarks
- [ ] **smell-8:** Split `federation.ex` (1,967 lines) — consider: Actors, Collections, Feed, Delivery
- [ ] **smell-9:** Split `inbox_handler.ex` (1,315 lines) — extract per-activity-type sub-modules

### Code Smells — Other

- [ ] **smell-10:** Remove deprecated `can_manage_article?/2` and its tests (`content.ex:647`, `article_edit_test.exs:79-122`)
- [ ] **smell-11:** Replace `try/rescue Ecto.NoResultsError` with non-raising `get_by` queries in `activity_pub_controller.ex:268,305`
- [ ] **smell-12:** Replace direct `Repo` calls in controller with context functions — 10 instances in `activity_pub_controller.ex`
- [ ] **smell-13:** Hoist function-local `alias` declarations to module level — scattered across 8+ modules (`content.ex`, `notification.ex`, `auth.ex`, `federation.ex`, `moderation.ex`, `settings_live.ex`)
- [ ] **smell-14:** Use `is_nil/1` instead of `!= nil` in cond blocks (`content.ex:1635,1734`)
- [ ] **smell-15:** Fix inconsistent `NaiveDateTime` usage in `sync_article_tags/1` — should use `DateTime.utc_now()` like all other `insert_all` calls (`content.ex:2117`)
- [ ] **smell-16:** Fix N+1 query: per-user follow-state lookup in loop — batch with single query (`search_live.ex:332-342`)
- [ ] **smell-17:** Move `Repo.preload` call from LiveView to Content context (`article_live.ex:842`)
- [ ] **smell-18:** Extract `Board.public?/1` predicate — `min_role_to_view == "guest"` checked 29 times across codebase
- [ ] **smell-19:** Extract `Board.federated?/1` predicate — `min_role_to_view == "guest" and ap_enabled` checked 6+ times
- [ ] **smell-20:** Replace `:httpc` with `Req` in `selenium_setup.ex:78` per CLAUDE.md convention
- [ ] **smell-21:** Extract `@max_comment_depth 5` module attribute — hardcoded in `content.ex:1370` and `article_live.ex:539`
- [ ] **smell-22:** Merge `@comments_per_page` and `@per_page` — both equal 20, defined 1282 lines apart (`content.ex:40,1322`)
- [ ] **smell-23:** Fix `can_forward_article?/2` divergence — different logic in `Content` vs `article_live.ex:759` (LiveView adds `article.forwardable` check)
- [ ] **smell-24:** Fix silently discarded `Repo.update()` result in `create_message/3` — conversation `last_message_at` update not transactional (`messaging.ex:267-295`)
- [ ] **smell-25:** Narrow bare `rescue e` to expected exception types in image/avatar processing (`article_image_storage.ex:65`, `avatar.ex:50`)

---

### UI/UX Accessibility — Critical

- [ ] **a11y-1:** Add focus trapping to div-based modals — keyboard users can tab through background content (all admin/user modals using DaisyUI `modal-open`)

### UI/UX Accessibility — Major

- [ ] **a11y-2:** Replace `<div role="button">` dropdowns with `<button>` elements — Space key doesn't activate without keydown handler (`layouts.ex:35,232`)
- [ ] **a11y-3:** Associate poll expires `<select>` with its `<label>` — use `for=`/`id` or nest inside label (`article_new_live.html.heex:196`)
- [ ] **a11y-4:** Add `aria-modal="true"` to `<dialog>` and use `.showModal()` for proper focus trap (`profile_live.html.heex:48`)
- [ ] **a11y-5:** Add `aria-hidden="true"` on icons and `sr-only` prefixes in password reset strength checklist — register page has it, reset page doesn't (`password_reset_live.html.heex:79-148`)
- [ ] **a11y-6:** Add `role="tabpanel"` with `aria-labelledby` to search result content panels (`search_live.html.heex:161`)
- [ ] **a11y-7:** Add `aria-label` to conversation unread count badges (`conversations_live.html.heex:51`)
- [ ] **a11y-8:** Add `phx-disable-with` loading feedback to form submit buttons — missing from comment post, article create/edit, login, register, etc.
- [ ] **a11y-9:** Associate notification preference checkboxes with `<label>` elements (`profile_live.html.heex:307`)

### UI/UX Accessibility — Minor

- [ ] **a11y-10:** Add initial `aria-expanded="false"` to dropdown triggers (`layouts.ex:37,233`)
- [ ] **a11y-11:** Change profile page heading from `<h2>` to `<h1>` (`profile_live.html.heex:3`)
- [ ] **a11y-12:** Add `id` to `<h1>` headings on feed, notifications, conversations, following pages for `aria-labelledby`
- [ ] **a11y-13:** Add `aria-labelledby` to `<article>` list items pointing to title links (`board_live.html.heex`, `search_live.html.heex`, `feed_live.html.heex`, `tag_live.html.heex`)
- [ ] **a11y-14:** Add per-comment context to reply button `aria-label` — multiple "Reply" buttons indistinguishable (`article_live.ex`)
- [ ] **a11y-15:** Include locale name in move up/down button `aria-label` (`profile_live.html.heex:162-191`)
- [ ] **a11y-16:** Wrap board checkboxes in `<fieldset>/<legend>` or `role="group"` (`article_new_live.html.heex:212`)
- [ ] **a11y-17:** Wrap poll mode radio buttons in `<fieldset>/<legend>` or `role="radiogroup"` (`article_new_live.html.heex:169`)
- [ ] **a11y-18:** Use `<ins>`/`<del>` HTML elements in article history diff — insertions only distinguished by color (`article_history_live.html.heex:83`)
- [ ] **a11y-19:** Add `aria-hidden="true"` to inline SVG icon in user invites alert (`user_invites_live.html.heex:10`)
- [ ] **a11y-20:** Add `aria-pressed` to board follows policy toggle buttons (`board_follows_live.html.heex:27`)
- [ ] **a11y-21:** Add `aria-label` to avatar placeholder divs for actor identity (`core_components.ex:577`)
- [ ] **a11y-22:** Add "opens in new tab" warning to `target="_blank"` image gallery links (`article_live.html.heex:153`)
- [ ] **a11y-23:** Add `data-focus-target` to search, conversations, following list pages
- [ ] **a11y-24:** Add `aria-live="polite"` to remote actor loading indicator (`search_live.html.heex:71`)
- [ ] **a11y-25:** Add `type="button"` to comment like button (`article_live.ex`)

---
