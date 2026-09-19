# 0049 — User-facing changesets are allow-lists

- **Status:** Accepted
- **Date:** 2026-09-19
- **Deciders:** Baudrate maintainers
- **Related:** the identity half of this is
  [0046](0046-every-identity-claim-is-bound-to-the-host-that-can-prove-it.md),
  which stops a *remote* instance minting a URI on someone else's host. This
  stops a *local member* minting one on a remote host — the same squat from the
  other side of the boundary, and the reason both must hold at once. Recorded
  retroactively; the rule has been in the code since the columns existed.

## Context

An Ecto changeset's `cast/3` takes the fields a caller may set, and the
tempting way to write one is to list the schema's columns. Doing that is
invisible in review: the changeset validates, the form works, the tests pass.
What it also does is hand every column that happens to be on the table to
whoever posts the form.

The columns that matter here are the ones the *system* fills in, next to the
ones a member types:

| Column | Who really sets it | What casting it gives a member |
|---|---|---|
| `ap_id` | stamped post-insert by the context, from the DB-assigned id | it is **unique**, so squatting a remote object's URI means the genuine post is later dropped as a duplicate — and this instance serves the local one in its place |
| `url` | the feed entry, for bot posts | an arbitrary "View original" link on their own article, rendered as an `href` |
| `published_at` | the feed entry's own date | a backdated post, and the timeline orders on this column |
| `parent_id` | the server, from the reply target | a comment threaded under a comment in a board they cannot open |
| `visibility` | the composer, from two choices | `followers_only` or `direct` on board content, which is not a thing local articles have |

None of these is a privilege-escalation in the usual sense — the member is
allowed to post. They are all the same shape: a field that means "the system
established this" being writable by the person the system is establishing it
about.

## Decision

**A changeset reachable from user input casts an explicit list of the fields a
user may set, and nothing else.** The list is a module attribute so it reads as
a list rather than as a line of `cast/3`:

1. **`Article.changeset/2` casts `@user_fields`** — `title`, `body`, `slug`,
   `user_id`, `forwardable`, `visibility`. `ap_id` is stamped post-insert by
   `Articles.create_article/3`, because the canonical URI contains the row's
   id and cannot exist before the insert.
2. **Trusted callers get their own function, never a flag.**
   `Article.trusted_changeset/2` casts `@user_fields ++ [:ap_id, :url,
   :published_at]` and is reached only through
   `Content.create_article(attrs, boards, trusted: true)` — the RSS/Atom bots,
   whose feed entries legitimately carry all three. A boolean on the user-facing
   changeset would put the two paths one typo apart.
3. **Remote objects get a third function.** `remote_changeset/2` casts what a
   peer supplies, and everything in it is bounded and validated separately
   (0046 for the URIs, the https-only `url` check, the `published_at` clamp).
   Three functions, three trust levels, none of them a parameter.
4. **`Comment.changeset/2` never casts `ap_id`**, for the same reason.
5. **The LiveViews narrow again before the context sees the params.** The
   composers `Map.take` the form's own fields
   (`~w(title body forwardable visibility)`, `~w(body visibility)`) and set
   `parent_id` from the server-side reply target, never from the form. This is
   belt and braces on purpose: the changeset is the enforcement point, and the
   `Map.take` means a field added to the schema tomorrow is not silently
   accepted by a form written today.
6. **Local content offers only `public` and `unlisted`**
   (`@local_visibilities`), validated by inclusion. Board content is public on
   this site whatever its addressing, and direct messages are the private
   channel (D1).

## Alternatives considered

- **Cast the whole schema and block the dangerous fields with `validate_*`.**
  A deny-list, and it fails the way deny-lists fail: the next column added to
  `articles` is castable the moment it exists, and nobody writing that
  migration is thinking about this record.
- **One changeset with an `opts` flag for trusted callers.** Rejected under
  decision 2. The bot path and the member path would differ by one argument at
  a call site, and the failure is silent.
- **Enforce it in the context instead of the changeset.** The context is where
  authorization goes ([0016](0016-authorization-at-the-context-boundary.md)),
  but this is not authorization — it is what a field *means*. Putting it in the
  changeset keeps it next to the schema, where the next person to add a column
  is already looking.
- **Trust the LiveView's `Map.take`.** It is the layer most likely to be
  rewritten, copied into a new composer, or bypassed by a future API. Decision
  5 keeps it as a second line, not the line.

## Consequences

- Adding a column to `articles` or `comments` means deciding which of the three
  changesets it belongs in. Forgetting means the field cannot be set at all,
  which surfaces immediately — the failure direction this is chosen for.
- A bot's article carries a `url` and a `published_at` that a member's cannot.
  That asymmetry is deliberate and is why `published_at` is nil for local posts.
- `ap_id` being stamped after the insert means the article exists for a moment
  without its URI. Publishing happens inside the same transaction
  ([0034](0034-federation-work-is-committed-before-it-is-acknowledged.md)), so
  nothing observes that gap.
- This record and 0046 have to hold together: 0046 keeps a remote host from
  minting our URIs, this keeps a local member from minting theirs. Either one
  alone leaves the unique `ap_id` column squattable from one side.

## Acceptance gate

`test/baudrate/content/article_test.exs`, "changeset/2 allow-list" — that
`ap_id`, `url` and `published_at` are not cast from user input, that
`trusted_changeset/2` does cast the latter two, and that `remote_changeset/2`
refuses a non-https `url`. A new user-facing changeset with a
system-established column belongs beside it.
