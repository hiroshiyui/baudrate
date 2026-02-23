# Baudrate — Project TODOs

Audit date: 2026-02-23

---

## Medium: Feature Gaps

- [x] **RSS/Atom feeds** — `/feeds/rss`, `/feeds/atom`, `/feeds/boards/:slug/rss|atom`, `/feeds/users/:username/rss|atom`
- [ ] **Bulk moderation actions** — one-at-a-time only; no bulk delete/ban in admin
- [ ] **User muting** — blocking exists (AP Block activity) but no local-only soft-mute/ignore

## Low: Deployment & Infrastructure

- [ ] **Create Containerfile** — no containerization support (Podman)
- [ ] **Create podman-compose.yml** — no local dev environment template
- [ ] **Add `rel/` release config** — `mix release` not configured for production
- [ ] **Write deployment guide** — no deployment documentation exists
- [ ] **Add `.env.example`** — no environment config template

## Planned Features

### Board-Level Remote Follows (Moderator-Managed)

Allow moderators to follow remote Fediverse actors on behalf of boards, pulling
their content into the board. Requires anti-loop and deduplication safeguards.

#### Anti-Loop / Anti-Duplication Rules

1. **Never re-announce an Announce** — content arriving via `Announce` is stored
   and linked to the board but does NOT trigger an outbound `Announce`. Only
   content arriving via `Create` (directly authored) gets announced to followers.
2. **Cross-board announce dedup** — before a board announces an article, check if
   any local board has already announced the same `ap_id`. First board wins.
3. **Origin/addressing check** — only announce articles where the board's actor
   URI appears in the activity's `to` or `cc` (intentionally addressed, not relayed).
4. **Outbound announce rate limit** — cap Announces per board per time window
   (e.g., 30/hour) to prevent flood from a prolific followed actor.

#### Implementation Notes

- Rules 1 + 2 are the minimum viable safeguards
- Rules 3 + 4 are defense-in-depth
- Need a new `board_follows` table (board_id, remote_actor_id, followed_by_id)
- Need UI in board moderator panel to manage follows
- Need to handle `Undo(Follow)` on unfollow

## Someday / Maybe: Frontend Architecture

Decouple the frontend from Phoenix LiveView to allow free choice of UI framework
and component libraries. LiveView's tight coupling between server and UI limits
frontend technology options (e.g., Web Component libraries like Fluent UI are
incompatible with LiveView's DOM patching model).

### Approaches

- [ ] **JSON API backend** — convert Phoenix to a pure API server (`Phoenix.Controller` + `Phoenix.Router`), serve a standalone SSR frontend (Next.js, Nuxt, SvelteKit, Astro, etc.)
- [ ] **Incremental migration** — add new pages in the SPA framework while keeping existing LiveView pages, route via reverse proxy; migrate page-by-page over time
- [ ] **Hybrid approach** — keep LiveView for admin/internal pages, use a standalone frontend for public-facing pages only

### Trade-offs

| Gain | Loss |
|------|------|
| Free choice of UI framework/component library | LiveView's real-time WebSocket updates |
| Better frontend tooling ecosystem | Server-driven forms (no client state bugs) |
| Easier to hire frontend developers | Zero-API-layer simplicity |
| SSR framework flexibility (React, Vue, Svelte) | Must build and maintain a REST/GraphQL API |
| Independent frontend deployment | API versioning and compatibility burden |

### Preferred Frontend Framework

- **SvelteKit** — top candidate; compiled approach (no virtual DOM overhead), built-in SSR/SSG, form actions, file-based routing, small bundle size

### Prior Evaluation

- **Fluent UI Web Components v3** (2026-02-23): evaluated and rejected for use with LiveView due to Shadow DOM / DOM patching incompatibility, form binding friction, pre-release stability risk, and 5-7x bundle size increase over DaisyUI

## Someday / Maybe

- [ ] Two-way visibility blocking (blocked users can still see public content)
- [ ] Per-user rate limits on authenticated endpoints (currently IP-only)
- [ ] Authorized fetch mode test coverage (signed GET fallback)
