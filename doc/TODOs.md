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
