# Baudrate — Project TODOs

---

## Feature Backlog

Identified via competitive analysis against Discourse, Lemmy, Flarum, NodeBB, and Misskey.

### High Priority — Core Forum Gaps

- [ ] **feat:** Bookmarks / saved posts — users can bookmark articles and comments for later; simple join table, dedicated `/bookmarks` page
- [ ] **feat:** Drafts / autosave — auto-save article and comment drafts (DB-backed or localStorage); restore on revisit
- [ ] **feat:** Polls — inline polls in articles (single-choice, multiple-choice, with optional expiry); federate as `Question` AP object
- [ ] **feat:** Rich link previews (oneboxing) — auto-expand YouTube, GitHub, Wikipedia, etc. links into embedded cards with metadata

### Medium Priority — Moderation & Discovery

- [ ] **mod:** Watched words / auto-filters — admin-configurable keyword lists that auto-flag, auto-censor, or require approval
- [ ] **mod:** Spam detection integration — Akismet or StopForumSpam integration for registration and posting
- [ ] **mod:** Moderator notes on users — private mod-only notes on user profiles for context sharing between moderators
- [ ] **mod:** Similar topic suggestions — when creating an article, show existing articles with similar titles to prevent duplicates
- [ ] **mod:** Advanced search operators — filter by author, date range, board, tag, has:images in search
- [ ] **mod:** Tag management — admin-managed tag taxonomy with synonyms, hierarchy, and per-board required tags
- [ ] **mod:** Slow mode — per-topic reply rate limiting for heated threads
- [ ] **mod:** Split/merge threads — moderator tools to split off-topic replies into new threads or merge duplicate threads

### Medium Priority — Federation

- [ ] **federation:** ActivityPub relay support — connect to relays for wider content distribution across small instances
- [ ] **federation:** User-level instance blocking — users can block entire remote instances from their personal feed
- [ ] **federation:** Emoji reactions via federation — support custom emoji reactions beyond `Like`; interop with Misskey/Firefish
- [ ] **federation:** Account migration (Move) — implement the `Move` activity handler for user portability between instances
- [ ] **federation:** Federated moderation — allow remote moderators to act on boards they moderate

### Lower Priority — Engagement & Platform

- [ ] **feat:** Badges / achievements — milestone-based badges rewarding active contributors (first post, 100 articles, etc.)
- [ ] **feat:** Trust levels / reputation — automated privilege escalation based on user activity (post count, time spent, likes received)
- [ ] **infra:** Outbound webhooks — fire HTTP webhooks on events (article created, user registered, etc.) for Slack/Discord/CI integration
- [ ] **infra:** Public REST API — documented API for third-party client development and integrations
- [ ] **infra:** S3 / CDN object storage — external media storage for horizontal scaling (currently local filesystem only)
- [ ] **infra:** Admin analytics dashboard — DAU/MAU, posts/day, response times, community health metrics
- [ ] **a11y:** RTL language support — right-to-left layout for Arabic/Hebrew communities
- [ ] **infra:** Plugin / extension system — third-party extensibility API

---

## Audit Report: Notification System + Web Push + PWA Manifest (Phases 1–7)

Audit date: 2026-02-27

### Critical Security Issues

- [x] **S3:** No rate limiting on push subscription API — added `:push_subscription` rate limit (10/min) with JSON 429 response

### High Correctness Issues

- [x] **C1:** Remote actor block/mute not checked — added `check_blocked_or_muted/1` clause for `actor_remote_actor_id`
- [x] **C3:** DER signature parsing crash — `der_to_raw_p256/1` now returns `{:ok, binary} | {:error, :invalid_der}` with safe pattern match
- [x] **C4:** Signature component overflow in `pad_or_trim_to_32` — added hard truncation fallback for >32 non-zero bytes

### Web Push Cryptography Issues

- [x] **C5:** Confirmed false positive — HKDF parameter order is correct per RFC 8291; added clarification comment

### Medium Severity Issues

- [x] **M1:** N+1 query in preference check — user loaded once via `fetch_recipient/1` and passed through pipeline
- [x] **M3:** No loading state on push buttons — added `setLoading()` with disabled state and loading class
- [x] **C6:** Unbounded web push signature component sizes — `r_len`/`s_len` now validated to 1..33 range

### Low Severity Issues

- [x] **L1:** Missing `aria-labelledby` on push manager — added `role="region"` and `aria-labelledby`
- [x] **L2:** Notification for deleted article shows empty body — added `is_nil(deleted_at)` check in body/url
- [x] **L3:** Preference check returns `:ok` for deleted user — `fetch_recipient/1` returns `{:ok, nil}`, handled gracefully
- [x] **L4:** Service worker error handling conflates errors — differentiated `NotAllowedError` from other errors with reason details

### Test Coverage Gaps

- [x] **T1:** No tests for remote actor block/mute notification suppression — added block + mute tests
- [x] **T5:** No soft-delete content tests — added soft-delete article push notification test
- [ ] **T6:** No RFC 8291 test vectors — deferred (requires implementing decryption)
- [x] **T7:** No DER edge case tests — added 50-iteration signature size consistency test

### Bug Fixes (discovered during audit)

- [x] `web_push.ex:278` referenced `.preferred_username` but `RemoteActor` schema uses `.username`
