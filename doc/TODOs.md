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

- [x] **sec-1:** Add `:rate_limit_mount` to `:authenticated` live_session — authenticated users bypass WebSocket mount rate limit (`router.ex:228`)
- [x] **sec-2:** Add explicit `length:` option to `Plug.Parsers` — defaults to 8MB for non-AP browser requests (`endpoint.ex:77`)
- [x] **sec-3:** Document `SECRET_KEY_BASE` rotation impact — rotating invalidates all encrypted TOTP secrets and federation private keys (`totp_vault.ex`, `key_vault.ex`)
- [x] **sec-4:** Block IPv6 multicast range (`ff00::/8`) in SSRF `private_ip?/1` check (`http_client.ex:253`)

---

### Test Coverage — Missing Tests

- [x] **test-1:** Add tests for `notify_local_article_liked/2` and `notify_local_comment_liked/2` (`notification_hooks_test.exs`)
- [x] **test-2:** Add tests for `build_like_article/2`, `build_undo_like_article/2`, `publish_article_liked/2`, `publish_article_unliked/2` (`publisher_test.exs`)
- [x] **test-3:** Add tests for `toggle_comment_bookmark/2` and `comment_bookmarked?/2` (`content_test.exs`)
- [x] **test-4:** Add tests for `can_comment_on_article?/2` and `can_moderate_article?/2` (`content_test.exs`)
- [x] **test-5:** Add unit tests for `update_remote_poll_counts/2`, `recalc_poll_counts/1`, `create_remote_poll_vote/1` (`content_test.exs`)
- [x] **test-6:** Add test for `unread_counts_for_conversations/2` (`messaging_test.exs`)
- [x] **test-7:** Add test for `publish_key_rotation/2` (`publisher_test.exs`)
- [x] **test-8:** Add unit test for `delete_article_like_by_ap_id/2` (2-arity, remote_actor_id guard) (`content_test.exs`)

### Test Coverage — Anti-Patterns

- [x] **test-9:** Replace `Process.sleep(1100)` with `Repo.update_all` timestamp backdating for ordering test (`messaging_test.exs:293`)
- [x] **test-10:** Move delivery hooks test to separate `async: false` module — shared sandbox in async test is dangerous (`content_test.exs:524-575`)
- [x] **test-11:** Remove unnecessary `Process.sleep(50)` in publisher tests — synchronous with `federation_async: false` (`publisher_test.exs:52,306,331,373`)
- [x] **test-12:** Replace broad `length(jobs) >= 1` assertions with exact count + inbox URL checks (`publisher_test.exs:430,447,477,494`)

---

### Documentation

- [ ] **doc-11:** Improve `@spec` coverage across context modules — ~85 missing in `content.ex`, ~48 in `auth.ex`, ~60 in `federation.ex`, 31 in `publisher.ex`

---

### Code Smells — Duplicated Code

- [ ] **smell-1:** Extract `user_can_view_article?/2` to `Content` — duplicated in `article_live.ex:776` and `article_history_live.ex:64`
- [ ] **smell-2:** Unify `has_unique_constraint_error?` — triplicated in `content.ex:1912`, `notification.ex:296`, `inbox_handler.ex:1061`
- [ ] **smell-3:** Extract `Content.batch_comment_counts/1` — duplicated batch comment count query in `content.ex:308` and `federation.ex:1477`
- [ ] **smell-4:** Extract private `do_toggle_like/4` — `toggle_article_like` and `toggle_comment_like` have near-identical structure (`content.ex:1628,1727`)
- [x] **smell-5:** Extract private `not_found(conn)` helper — 404 JSON response repeated 18 times in `activity_pub_controller.ex`
- [ ] **smell-6:** Extract shared `with_rate_limit_or_admin/3` — admin rate-limit bypass pattern repeated in 3 handlers in `article_live.ex`

### Code Smells — Other

- [x] **smell-10:** Remove deprecated `can_manage_article?/2` and its tests (`content.ex:647`, `article_edit_test.exs:79-122`)
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
- [x] **smell-23:** Fix `can_forward_article?/2` divergence — different logic in `Content` vs `article_live.ex:759` (LiveView adds `article.forwardable` check)
- [ ] **smell-24:** Fix silently discarded `Repo.update()` result in `create_message/3` — conversation `last_message_at` update not transactional (`messaging.ex:267-295`)
- [ ] **smell-25:** Narrow bare `rescue e` to expected exception types in image/avatar processing (`article_image_storage.ex:65`, `avatar.ex:50`)

---
