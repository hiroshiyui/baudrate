# Baudrate — Project TODOs

---

## Feature Backlog

Identified via competitive analysis against Discourse, Lemmy, Flarum, NodeBB, and Misskey.

### High Priority — Core Forum Gaps

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
