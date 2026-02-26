# Baudrate — Project TODOs

Audit date: 2026-02-26

---

## High Priority

- [x] **perf:** `board_ancestors/1` loads ALL boards into memory — replaced with iterative `Repo.get` (max 10 PK lookups)
- [x] **perf:** 5 redundant `Repo.preload(:boards)` per article page — added `ensure_boards_loaded/1` using `Ecto.assoc_loaded?/1`
- [x] **infra:** Add `/health` endpoint for load balancers and monitoring — `GET /health` with DB connectivity check
- [x] **infra:** `DeliveryWorker` graceful shutdown — `terminate/2`, `shutting_down` flag, `Task.Supervisor.async_stream_nolink`
- [x] **security:** WebSocket-level rate limiting on public LiveView mounts — `:rate_limit_mount` hook (60/min/IP)
- [x] **test:** Admin LiveView test coverage — 9 test files under `test/baudrate_web/live/admin/`

## Medium Priority

- [ ] **federation:** No outbound `Delete(Note)` when a comment is soft-deleted — remote instances never learn (`content.ex:1122-1135`)
- [ ] **federation:** `@context` is a plain string, missing `"https://w3id.org/security/v1"` — strict JSON-LD parsers can't resolve `publicKey` (`federation/publisher.ex:22`)
- [ ] **federation:** No `hs2019` signature algorithm support — newer Mastodon instances may be rejected (`federation/http_signature.ex:5`)
- [x] **security:** Object `id` in incoming activities not validated as HTTPS URL before storing as `ap_id` — added `validate_object_id/1` to Validator, guarded all extraction points in InboxHandler
- [x] **security:** CSP `img-src https:` allows tracking pixels from federated content — removed blanket `https:` from `img-src`
- [x] **security:** Add `Referrer-Policy` header and `object-src 'none'` to CSP — added `referrer-policy: strict-origin-when-cross-origin` and `object-src 'none'`
- [ ] **perf:** `domain_blocked?/1` queries DB settings on every inbox/outbox activity — cache in ETS or Agent (`federation/validator.ex:81-93`)
- [ ] **perf:** No partial index on `comments(article_id) WHERE deleted_at IS NULL` for common query pattern
- [ ] **perf:** Board article listing joins ALL comments for bump ordering — denormalize to `last_activity_at` column on articles (`content.ex:212-225`)
- [ ] **a11y:** No `aria-live` regions for dynamically updated content (comment lists, search results)
- [ ] **infra:** `DeliveryWorker` polling has no jitter — thundering herd risk in clusters (`federation/delivery_worker.ex:45`)
- [ ] **infra:** No telemetry events for federation delivery despite having telemetry deps
- [ ] **code:** `headers_to_list/1` in `delivery.ex` is a no-op identity function — remove (`federation/delivery.ex:311-313`)
- [ ] **code:** `Mix.env()` used at runtime in `http_client.ex` — will crash in releases (`federation/http_client.ex:216`)
