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
- [ ] **mod:** Tag management — admin-managed tag taxonomy with synonyms, hierarchy, and per-board required tags
- [ ] **mod:** Slow mode — per-topic reply rate limiting for heated threads
- [ ] **mod:** Split/merge threads — moderator tools to split off-topic replies into new threads or merge duplicate threads

### Lower Priority — Engagement & Platform

- [ ] **infra:** Admin analytics dashboard — DAU/MAU, posts/day, response times, community health metrics
- [ ] **infra:** S3 / CDN object storage — external media storage for horizontal scaling (currently local filesystem only)

---
