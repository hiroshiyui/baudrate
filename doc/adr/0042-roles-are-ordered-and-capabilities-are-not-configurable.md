# 0042 — Roles are ordered, and capabilities are not configurable

- **Status:** Accepted
- **Date:** 2026-09-18
- **Deciders:** Baudrate maintainers
- **Supersedes** the *capabilities* half of
  [0011](0011-role-levels-for-board-authorization.md). The per-board half of
  0011 — ordered role levels, `min_role_to_view`/`min_role_to_post`, board
  moderators as an orthogonal grant — stands unchanged and is load-bearing.

## Context

ADR 0011 divided authorization in two. *Capabilities* ("may this account do
this kind of thing at all?") were to use a normalized 3-table RBAC design with
`scope.action` names, configurable by a sysop. *Per-board access* was to use
ordered role levels, because a permission-name ACL cannot express "visible to
moderators and above" without synthesising a permission per board.

The per-board half was built, and fourteen months later it carries most of the
site: 40 references across 15 files, plus every listing query through
`Filters.allowed_view_roles/1`.

The capability half was **seeded and never wired**. An audit of the whole
authorization surface on 2026-09-18 found:

- **No write path.** `role_permissions` rows are inserted once by
  `Setup.seed_roles_and_permissions/0`, from the hard-coded
  `Setup.default_permissions/0`. There is no admin route, no context function
  and no web-layer code that edits them; `grep RolePermission lib/baudrate_web/`
  returns nothing. `Setup.has_permission?/2` is therefore a constant function
  of a compile-time map, and every "permission check" is an indirect,
  DB-round-tripping way of asking *is this role admin?*
- **Four of eleven permissions are consulted at all.**
  `admin.manage_roles`, `moderator.sanction_user`, `admin.manage_users` and
  `user.create_content`. The other seven enforce nothing.
- **The real mechanism is the role name.** 29 authorization decisions compare
  `role.name` against `"admin"` or `["admin", "moderator"]` — more than the
  sanctions gate (20 call sites), the role-level system (7 direct) and the
  permission system (6 lines) combined. Every `on_mount` hook tests a role
  name, never a level and never a permission.
- **"Higher roles inherit lower-role permissions"**, as `Setup`'s own
  moduledoc and `doc/development.md` both stated, was never implemented:
  `has_permission?/2` does an exact `(role_name, permission_name)` join. The
  11/8/4/1 permission counts are flattened copies written at seed time.

So the catalogue is presented to an operator as a matrix describing who can do
what, and it is documentation with one enforcing edge.

## Decision

**Roles are a fixed, totally ordered set of four: `guest` < `user` <
`moderator` < `admin`.** This is now a decision rather than an implementation
detail. `@role_levels` in `Baudrate.Setup` is the single source; there is no
`create_role/1` and none is wanted.

**Capabilities are not configurable, and the catalogue stops claiming to be.**
`Setup.default_permissions/0` is kept for the four permissions that do real
work and as the seed for `roles`/`permissions`/`role_permissions`, which
`Setup.has_permission?/2` reads. The remaining seven are named in
`test/baudrate/setup/permissions_are_enforced_test.exs`'s `@known_unenforced`,
which fails the build if an eighth appears, so the gap cannot widen quietly.

**Authorization is expressed in whichever of four mechanisms fits, and each has
one definition:**

| Question | Mechanism |
|---|---|
| May this account act at all? | `Auth.ensure_can_interact/1` (ADR 0029) |
| May it see or post in this board? | role level vs `min_role_to_view`/`min_role_to_post` |
| May it moderate *this* board? | `board_moderators` membership |
| Is it staff / an admin? | role name, at the route hook and in the context |

The fourth is legitimate and is not a defect to be refactored into the
permission system. What *is* a defect is having the same question answered in
two places with two answers, which is what this audit found three times.

## Consequences

- **A sysop cannot vary capability independently of rank.** Granting a
  moderator one admin power, or taking one away, means editing code. This is
  the cost we are accepting, and it is the cost 0011 tried to avoid.
- **A non-comparable role does not fit**, as 0011 already warned. Board
  moderators are the sanctioned escape hatch: a per-board grant, orthogonal to
  the ordering. Anything else needs a new ADR, and the honest answer will
  usually be another orthogonal grant rather than a fifth level.
- **`admin.manage_roles` is the one permission with no role-name
  alternative**, and it gates role reassignment — privilege escalation. Keep it
  enforced at the context boundary.
- **The docs stop promising configurability.** `doc/development.md`'s RBAC
  section and `Setup`'s moduledoc drop the inheritance claim, which was false.
- A future decision to build the admin UI and wire the seven dead permissions
  is not foreclosed; it supersedes this record rather than resuming 0011.

## Defects this audit found, fixed alongside

Each contradicted a decision already written down, which is why they are
listed here rather than only in the changelog:

- **`Auth.ban_user/3` checked neither the permission nor the rank rule.** ADR
  0029 requires both of every sanction, and `Sanctions.issue/4` applies both —
  so a moderator could not silence a peer for an hour, while `ban_user/3`
  would permanently ban an admin for any caller. Now
  `Sanctions.authorize_ban/2`, in the module that owns the rank rule.
- **"May this user see this article?" had three implementations.** The
  canonical one lived in `BaudrateWeb.ArticleHelpers` — the web layer, against
  ADR 0016 — and the context's copy omitted both remote refusals while keeping
  a third hand-written copy of the role hierarchy. A followers-only remote
  article was refused by `/articles/:slug` and accepted by like, boost,
  bookmark and forward. `Content.Interactions.remote_servable?/1` is now the
  one definition and the LiveView asks it.
- **`Permissions.can_forward_article?/2`'s admin clause returned before any
  visibility test**, so an admin could forward a followers-only remote article
  into a board and re-publish it `as:Public` — against ADR 0030 and CLAUDE.md's
  "including admins". The remote refusal now precedes both exemptions.

## Alternatives considered

- **Finish the capability system**: build `/admin/roles`, wire the seven dead
  permissions, replace the 29 role-name checks. Rejected for now, not on
  principle: it is the largest change of the three, it re-opens the total
  ordering question, and nothing has yet needed a capability that does not
  follow rank. A forum with four roles is the case 0011 itself called "far
  more machinery and UI than needed" when rejecting per-object ACLs.
- **Delete the permission tables entirely** and make the role-name checks
  explicit. Tempting, and it is the most honest description of the code.
  Rejected because the four live permissions do real work, and
  `admin.manage_roles` has no role-name equivalent — deleting it would move
  privilege escalation behind a hard-coded string.
- **Derive permissions from role level at runtime** (real inheritance, so
  `admin` automatically holds every lower permission). Rejected: it makes the
  matrix a pure function of the ordering, which is the ordering we already
  have, and it would hide that the catalogue adds nothing.
