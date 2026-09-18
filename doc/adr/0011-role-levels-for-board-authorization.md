# 0011 — Ordered role levels plus per-board minimums for authorization

- **Status:** Accepted, except the configurable-capabilities half,
  superseded by [0042](0042-roles-are-ordered-and-capabilities-are-not-configurable.md).
  The per-board half — ordered role levels, `min_role_to_view`/`min_role_to_post`,
  board moderators — stands.
- **Date:** Recorded retroactively 2026-08-09

## Context

Baudrate needs two different kinds of authorization decision:

1. *Can this user perform this kind of action at all?* — e.g. manage users,
   create content. This is a capability question.
2. *Can this user see or post in this board?* — a per-object question that a
   sysop must be able to set per board, from the admin UI, without editing
   code or inventing new permission names.

A pure permission-name ACL answers (1) well and (2) badly: expressing "this
board is visible to moderators and above" would require synthesising a
permission per board.

## Decision

Combine both, with a clear division of labour.

**Capabilities** use a normalized 3-table RBAC design (roles, permissions,
join) with `scope.action` names — `admin.manage_users`, `user.create_content`,
`guest.view_content`. Higher roles inherit all lower-role permissions.

**Per-board access** uses ordered role levels instead:

| Role | Level |
|---|---|
| guest | 0 |
| user | 1 |
| moderator | 2 |
| admin | 3 |

- `Setup.role_level/1` and `Setup.role_meets_minimum?/2` are the comparison
  primitives.
- Every board carries `min_role_to_view` (default `guest`) and
  `min_role_to_post` (default `user`).
- `Content.can_view_board?/2` and `can_post_in_board?/2` are the enforcement
  points; `list_visible_top_boards/1` and `list_visible_sub_boards/2` apply the
  same filter to listings so a board a user cannot view never appears.

**Board moderators** are an orthogonal, per-board grant (`board_moderators`
join table). They may soft-delete articles and comments, pin/unpin, and
lock/unlock in their boards. They may **not** edit others' articles — editing
stays with the author and global admins. All their actions are written to the
moderation log.

Only boards with `min_role_to_view == "guest"` are federated (ADR 0004).

## Consequences

- A sysop can create a staff-only or members-only board from the admin UI with
  two dropdowns.
- The ordering is a real constraint: the model assumes roles are totally
  ordered. Introducing a role that is not comparable (a specialist with some
  admin powers and not others) does not fit and would need a new ADR.
- Two mechanisms must both be checked on write paths — `can_post_in_board?/2`
  checks the role minimum, active status **and** the `user.create_content`
  permission.
- Board visibility is a query-level filter, not a post-hoc one; a new listing
  query that forgets it leaks board existence.

## Alternatives considered

- **Permission names only.** Rejected: cannot express per-board minimums
  without synthesising permissions.
- **Full per-object ACLs.** Rejected: far more machinery and UI than a forum
  with four roles needs, and a much larger surface to get wrong.
