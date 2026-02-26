# Baudrate — Project TODOs

Audit date: 2026-02-26

---

## High Priority

- [ ] **perf:** `board_ancestors/1` loads ALL boards into memory — replace with recursive CTE or iterative `Repo.get` (`content.ex:81`)
- [ ] **perf:** 5 redundant `Repo.preload(:boards)` per article page — permission checks should skip preload when already loaded (`content.ex:459,476,506,516,532`)
- [ ] **infra:** Add `/health` endpoint for load balancers and monitoring (DB connectivity check, excluded from HSTS/SSL redirect)
- [ ] **infra:** `DeliveryWorker` has no graceful shutdown — add `terminate/2` callback to drain in-flight tasks (`federation/delivery_worker.ex`)
- [ ] **security:** No WebSocket-level rate limiting on public LiveView mounts (login, register, boards) — add rate limit in plug pipeline or Endpoint config
- [ ] **test:** Zero test coverage for all admin LiveViews (settings, users, boards, moderation, federation, invites, login attempts, moderation log, pending users)

## Medium Priority

- [ ] **federation:** No outbound `Delete(Note)` when a comment is soft-deleted — remote instances never learn (`content.ex:1122-1135`)
- [ ] **federation:** `@context` is a plain string, missing `"https://w3id.org/security/v1"` — strict JSON-LD parsers can't resolve `publicKey` (`federation/publisher.ex:22`)
- [ ] **federation:** No `hs2019` signature algorithm support — newer Mastodon instances may be rejected (`federation/http_signature.ex:5`)
- [ ] **security:** Object `id` in incoming activities not validated as HTTPS URL before storing as `ap_id` (`federation/validator.ex:54-69`)
- [ ] **security:** CSP `img-src https:` allows tracking pixels from federated content — consider proxying or restricting (`router.ex:54`)
- [ ] **security:** Add `Referrer-Policy` header and `object-src 'none'` to CSP (`router.ex:52-57`)
- [ ] **perf:** `domain_blocked?/1` queries DB settings on every inbox/outbox activity — cache in ETS or Agent (`federation/validator.ex:81-93`)
- [ ] **perf:** No partial index on `comments(article_id) WHERE deleted_at IS NULL` for common query pattern
- [ ] **perf:** Board article listing joins ALL comments for bump ordering — denormalize to `last_activity_at` column on articles (`content.ex:212-225`)
- [ ] **a11y:** No `aria-live` regions for dynamically updated content (comment lists, search results)
- [ ] **infra:** `DeliveryWorker` polling has no jitter — thundering herd risk in clusters (`federation/delivery_worker.ex:45`)
- [ ] **infra:** No telemetry events for federation delivery despite having telemetry deps
- [ ] **code:** `headers_to_list/1` in `delivery.ex` is a no-op identity function — remove (`federation/delivery.ex:311-313`)
- [ ] **code:** `Mix.env()` used at runtime in `http_client.ex` — will crash in releases (`federation/http_client.ex:216`)
