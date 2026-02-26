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

- [x] **federation:** No outbound `Delete(Note)` when a comment is soft-deleted — added `build_delete_comment/2` + `publish_comment_deleted/2` in Publisher, hooked into `soft_delete_comment/1`
- [x] **federation:** `@context` is a plain string, missing `"https://w3id.org/security/v1"` — all activities now use `[@as_context, @security_context]` array context
- [x] **federation:** No `hs2019` signature algorithm support — outbound signatures now use `hs2019` algorithm label (inbound still accepts both)
- [x] **security:** Object `id` in incoming activities not validated as HTTPS URL before storing as `ap_id` — added `validate_object_id/1` to Validator, guarded all extraction points in InboxHandler
- [x] **security:** CSP `img-src https:` allows tracking pixels from federated content — removed blanket `https:` from `img-src`
- [x] **security:** Add `Referrer-Policy` header and `object-src 'none'` to CSP — added `referrer-policy: strict-origin-when-cross-origin` and `object-src 'none'`
- [x] **perf:** `domain_blocked?/1` queries DB settings on every inbox/outbox activity — cached in ETS via `DomainBlockCache` GenServer
- [x] **perf:** No partial index on `comments(article_id) WHERE deleted_at IS NULL` — added partial index (migration `20260226160000`)
- [x] **perf:** Board article listing joins ALL comments for bump ordering — denormalized to `last_activity_at` column on articles (migration `20260226160001`)
- [x] **a11y:** No `aria-live` regions for dynamically updated content — added `aria-live="polite"` to all dynamically updated list containers and table bodies
- [x] **infra:** `DeliveryWorker` polling has no jitter — added ±10% random jitter to `schedule_poll/0`
- [x] **infra:** No telemetry events for federation delivery — added `:telemetry.execute/3` span events in `deliver_one/1` with metric definitions in `BaudrateWeb.Telemetry`
- [x] **code:** `headers_to_list/1` in `delivery.ex` was a map-to-list conversion disguised as identity — replaced with explicit `Map.to_list/1` and removed the private function
- [x] **code:** `Mix.env()` used at runtime in `http_client.ex` — replaced with `Application.compile_env(:baudrate, :allow_http_localhost, false)`
