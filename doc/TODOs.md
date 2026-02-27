# Baudrate — Project TODOs

Audit date: 2026-02-26

---

## Feature Backlog

Identified via competitive analysis against Discourse, Lemmy, Flarum, NodeBB, and Misskey.

### High Priority — Core Forum Gaps

- [x] **feat:** Notification system — in-app notification center (bell icon) for replies, mentions, new followers; DB-backed notification schema with read/unread state (Phase 1–5 done: schema, hooks, bell icon, notifications page, per-type preferences)
- [x] **feat:** @mention support — `@username` parsing in articles/comments, link to profile, trigger notification; federate as `Mention` tag in AP objects (Phase 2 done)
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

- [x] **feat:** Web Push notifications — push notifications via Web Push API for real-time alerts without visiting the site (Phase 6 done: VAPID, RFC 8291 encryption, service worker, subscription management)
- [ ] **feat:** Badges / achievements — milestone-based badges rewarding active contributors (first post, 100 articles, etc.)
- [ ] **feat:** Trust levels / reputation — automated privilege escalation based on user activity (post count, time spent, likes received)
- [ ] **infra:** Outbound webhooks — fire HTTP webhooks on events (article created, user registered, etc.) for Slack/Discord/CI integration
- [ ] **infra:** Public REST API — documented API for third-party client development and integrations
- [x] **infra:** PWA manifest — make Baudrate installable as a mobile app from the browser (Phase 7 done: site.webmanifest, theme-color meta, manifest link)
- [ ] **infra:** S3 / CDN object storage — external media storage for horizontal scaling (currently local filesystem only)
- [ ] **infra:** Admin analytics dashboard — DAU/MAU, posts/day, response times, community health metrics
- [ ] **a11y:** RTL language support — right-to-left layout for Arabic/Hebrew communities
- [x] **feat:** Theme engine — admin-configurable DaisyUI themes (35 built-in themes, light/dark selectors in admin settings)
- [ ] **infra:** Plugin / extension system — third-party extensibility API

---

## Implementation Plan: Notification System + Web Push + PWA Manifest

Baudrate currently has no notification system. Users receive no alerts for replies,
mentions, follows, or likes. This plan implements in-app notifications, @mention
parsing, Web Push (VAPID + RFC 8291), and a PWA manifest in 7 phases. Each phase
is independently functional and committable by topic.

### ~~Phase 1: Notification Schema, Context, and PubSub (Foundation)~~ ✅ Done

### ~~Phase 2: @Mention Parsing + Notification Creation Hooks~~ ✅ Done

### ~~Phase 3: Real-Time Bell Icon + Unread Count Badge~~ ✅ Done

### ~~Phase 4: Notifications Page (LiveView)~~ ✅ Done

### ~~Phase 5: Per-Type Notification Preferences~~ ✅ Done

### ~~Phase 6: Web Push (VAPID + Service Worker + Encryption)~~ ✅ Done

### ~~Phase 7: PWA Manifest + Docs~~ ✅ Done

---

## Audit Report: Notification System + Web Push + PWA Manifest (Phases 1–7)

Audit date: 2026-02-27

### Critical Security Issues

- [x] **S1:** SSRF via unvalidated push endpoint URL — `push_subscription.ex` accepts any URL; server POSTs to it later, enabling internal service attacks. **Fix:** `validate_endpoint_url/1` rejects non-HTTPS endpoints
- [x] **S2:** Open redirect in service worker — `service_worker.js` `clients.openWindow(url)` uses unvalidated URL from push payload; could be `javascript:` or phishing URL. **Fix:** `isSameOrigin()` check before `openWindow`
- [ ] **S3:** No rate limiting on push subscription API — `/api/push-subscriptions` endpoint has no rate limit plug; attacker can spam subscriptions
- [x] **S4:** Unbounded `per_page` parameter — `notification.ex` `list_notifications/2` accepts any integer; `per_page: 1_000_000` causes memory exhaustion. **Fix:** capped at `@max_per_page 100`

### High Correctness Issues

- [ ] **C1:** Remote actor block/mute not checked — `check_blocked_or_muted/1` only handles `actor_user_id` (local actors); federated actors bypass mute/block enforcement
- [x] **C2:** Missing p256dh/auth size validation — RFC 8291 requires p256dh=65 bytes, auth=16 bytes; invalid sizes crash `:crypto.compute_key` during delivery. **Fix:** `validate_binary_size/3` in controller
- [ ] **C3:** DER signature parsing crash — `vapid.ex` `der_to_raw_p256/1` uses bare pattern match; malformed DER causes `MatchError` crash
- [ ] **C4:** Signature component overflow in `pad_or_trim_to_32` — doesn't fail on >32 non-zero bytes; produces invalid 65+ byte signature

### Web Push Cryptography Issues

- [ ] **C5:** Incorrect RFC 5869 HKDF parameter order — `web_push.ex` HKDF implementation may have salt/IKM swapped vs. RFC 5869/8291

### Medium Severity Issues

- [ ] **M1:** N+1 query in preference check — every `create_notification` does `Repo.get(User, user_id)` + `web_push_enabled_for?/2` does another; 1000 announcements = 2000 extra queries
- [x] **M2:** 20+ English translations empty — empty `msgstr` for notification/push strings in `en/default.po`. **Fix:** filled all msgstr, removed fuzzy flags
- [ ] **M3:** No loading state on push buttons — `push_manager_hook.js` subscribe/unsubscribe have no UI feedback; double-click possible
- [ ] **C6:** Unbounded web push signature component sizes — `vapid.ex` no validation that `r_len`/`s_len` are valid P-256 values

### Low Severity Issues

- [ ] **L1:** Missing `aria-labelledby` on push manager — `profile_live.html.heex:252` accessibility issue
- [ ] **L2:** Notification for deleted article shows empty body — soft-deleted articles result in empty push notification body
- [ ] **L3:** Preference check returns `:ok` for deleted user — caught by FK constraint but poor design
- [ ] **L4:** Service worker error handling conflates errors — `push_manager_hook.js` conflates "unsupported" and "permission denied"

### Test Coverage Gaps

- [ ] **T1:** No tests for remote actor block/mute notification suppression
- [x] **T2:** No tests for push event handlers in ProfileLive — `push_support`, `push_subscribed`, `push_unsubscribed`, `toggle_web_push_pref`. **Fix:** 8 tests added
- [x] **T3:** No endpoint URL validation tests / p256dh/auth size validation tests. **Fix:** 3 SSRF tests + 2 size tests added
- [x] **T4:** No per-page bounds test. **Fix:** `caps per_page at 100` test added
- [ ] **T5:** No soft-delete content tests — notification behavior when referenced article/comment is deleted
- [ ] **T6:** No RFC 8291 test vectors — no actual decryption test for `encrypt/3`
- [ ] **T7:** No DER edge case tests — 33+ byte r/s, truncated/malformed DER, empty r/s
