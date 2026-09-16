# 0030 — Domain blocks are rows, and blocking hides content instead of deleting it

- **Status:** Accepted
- **Date:** 2026-09-16
- **Deciders:** Baudrate maintainers
- **Related:** extends [0026](0026-blocks-stop-interaction-locally.md) (a member's
  block) to whole instances; follows the shape of
  [0029](0029-sanctions-are-rows-with-an-explicit-end.md) (moderation decisions
  are rows with an author and a reason); constrains
  [0014](0014-ets-caches-for-settings-and-boards.md) (the ETS domain-block cache)

## Context

Instance-level federation moderation today is one `settings` row,
`ap_domain_blocklist`, holding a comma-separated list of domains, read through
`Federation.DomainBlockCache`. That single string is the whole model, and it
costs us six things.

**There is no record of the decision.** A domain block is a moderation act with
consequences for members who follow accounts there, but the list records only
the domain — not who blocked it, when, or why. When a second admin asks "why is
this one here?", nothing answers.

**There is no way to unblock from the dashboard.** `/admin/federation` can only
add: a one-click block on the instance list, plus "Add" and "Add All" from the
blocklist audit. Removing a domain means hand-editing the comma-separated
textarea in `/admin/settings`, where a mistyped separator silently unblocks
something else. A control that can only be pulled one way is not a moderation
tool.

**Concurrent writes lose entries.** Every block is a read-modify-write on one
string (`federation_live.ex:67` and `:241`, `setup.ex:435`). Two admins acting
at the same time, or "Add All" racing a settings save, drop blocks silently.
"Add All" also writes the setting once per domain, refreshing the whole cache
each time. And the two write paths disagree about what to record: blocking an
already-blocked domain from the instance list skips the audit entry, while
adding it from the audit writes one for a block that never happened.

**The list is parsed in four places.** `domain_block_cache.ex:108`,
`blocklist_audit.ex:99`, `federation_live.ex:70` and `:244`, and
`settings_live.ex:157` each re-implement the same
`split(",") |> trim |> downcase`. A list with a schema needs a table, not a
fifth copy of a parser.

**A block only stops future traffic.** The check runs at the inbox
(`inbox_handler.ex:68`), at delivery (`delivery.ex:153`), on DMs
(`messaging.ex:87`, `:290`) and on link previews
(`link_preview/fetcher.ex:116`). Everything the domain already sent stays
exactly where it was: its articles in boards, its comments under local
articles, its items in members' feeds. The follows in both directions also
survive, so the domain keeps a list of our members and we keep counting its
accounts as followers. Blocking a harassing instance leaves its harassment on
the page.

**The block does not stop us reaching out to the domain.** `validate_domain/1`
runs once signature verification has already resolved and cached the actor, so
a blocked domain still gets an outbound fetch from us and still gets a
`remote_actors` row. Three other outbound paths never consult the blocklist at
all: the media proxy (`media_controller.ex:66`) still fetches and caches the
domain's images, `ObjectResolver` still walks reply chains into it, and
`ActorResolver` still fetches its actors on demand. We block what it sends us
and keep asking it for things.

**There is no lever between a member's own block and blocking a whole
instance.** `Moderation.report_remote_actor/3` gives moderators a report about a
single remote account, and then nothing to do with it: they can tell the
reporter to block it personally, or block the account's entire domain and take
out every innocent account on it with it.

Decision **P1-D7** (2026-09-14) already settled the semantics: remove follows
both ways, hide the domain's existing content at query time so that unblocking
restores it, full blocks only with no silence or reject-media levels. What is
left to decide is where that state lives and how "hidden" is computed.

## Decision

1. **A domain block is a row in `domain_blocks`**, not a fragment of a
   setting: `domain` (unique, stored downcased), `reason` (why, for staff),
   `public_comment` (what we are willing to say publicly), `blocked_by_id`,
   `inserted_at`. Existing entries in `ap_domain_blocklist` migrate into rows
   and the setting is removed, so there is one authority and not two.

2. **`DomainBlockCache` stays the only read path** for the per-activity check.
   It reads rows in blocklist mode; **allowlist mode is unchanged** (P1-D7) and
   still reads `ap_domain_allowlist`, because an allowlist is a configuration
   choice about who may reach us at all, not a record of moderation decisions.

3. **Blocking and unblocking both happen from the Federation dashboard, both
   take a reason, and both are audited** (`block_domain` / `unblock_domain`,
   already in the moderation log's allow-list). The audit's "Add" and "Add All"
   write rows through the same function, so a bulk import carries its source.

4. **A block severs follows in both directions** for every actor on that
   domain, and sends nothing. This is the one place it differs deliberately
   from ADR 0026, where a member's block sends `Undo(Follow)` and
   `Reject(Follow)`: delivery to a blocked domain is refused by our own gate, so
   those activities could only fail in the queue. Unblocking restores no
   follows; they have to be made again, exactly as in ADR 0026.

5. **Hiding is a query-time filter, never a deletion.** One predicate decides
   whether a remote actor is *hidden*: its domain is blocked under the current
   federation mode, or the actor is individually suspended (below). Content
   whose author — or, for a boost, whose booster — is hidden is excluded from
   every listing a guest or a member can reach. Nothing is deleted and no
   column is stamped, so unblocking makes the content reappear by itself.

   This replaces a case-insensitive lookup with SQL equality, so
   `remote_actors.domain` — written straight from `URI.parse(ap_id).host` at
   `actor_resolver.ex:165` and never downcased — has to be normalized on write
   and backfilled. Today's ETS path downcases the key it looks up, which hides
   the inconsistency; a join does not, and an actor stored as `Example.COM`
   would quietly stay visible under a block on `example.com`.

6. **A single remote actor can be suspended instance-wide**
   (`remote_actors.suspended_at`, `suspended_by_id`, `suspend_reason`): its
   activities are refused at the inbox and its content is hidden, without
   touching the rest of its domain. It is the same predicate and the same
   reversibility, so a report about one remote account has an answer
   proportionate to it.

7. **Staff surfaces deliberately keep showing hidden content.** The moderation
   queue, the report detail and the instance detail page still render it, the
   way `reports.evidence_body` keeps removed text readable to staff (P1-D6).
   Moderators cannot judge what they cannot see, and a block is often applied
   before the content has been reviewed.

8. **Direct messages are not hidden.** A block refuses new ones, but messages
   already in a member's mailbox are that member's own correspondence, not a
   public listing, and they are often the evidence for a report. A member who
   wants them gone has their own block (ADR 0026) and can delete them.
   Notifications and reports that reference a hidden actor stay for the same
   reason: they are records addressed to one person, not a feed.

9. **A block stops us reaching out, not only listening.** The inbox decides on
   the host in the signature's `keyId` before resolving the actor, so a blocked
   domain gets neither an outbound request from us nor a cached `remote_actors`
   row; and the media proxy, `ObjectResolver` and `ActorResolver` consult the
   same gate, so we stop fetching its images, its reply chains and its actors.
   A block that still sends it traffic discloses our readers to an instance we
   have decided not to federate with, which is the concern ADR 0006 exists for.

10. **An acceptance test is the gate, not a review.** As
    `archive_test.exs` does for exports, one test seeds an article, a comment
    and a feed item from a blocked domain carrying a marker string and fails if
    the marker appears on any public or member-facing surface. "Everywhere a
    guest or member can look" is only true if something checks it.

## Consequences

- Blocking becomes reversible in practice, not just in principle: an admin who
  blocks the wrong domain, or blocks one precautionarily during an incident,
  undoes it with one click and the content comes back.
- Every listing that can contain remote content carries one more predicate, and
  a new listing that forgets it leaks blocked content until the acceptance test
  catches it. That test is therefore load-bearing and must grow with each new
  surface.
- The filter costs a semi-join against `remote_actors` on content queries. If
  that ever shows up in profiling, the answer is a denormalized flag maintained
  on block, unblock and federation-mode change — deliberately **not** taken now,
  because a flag can drift out of step with the rows and then either leaks
  blocked content or hides content that should be visible, and the drift is
  silent both ways.
- Members lose followers and follows when their instance is blocked, without
  the other side being told. That is inherent to blocking and is why the
  decision now carries a reason and an author.
- A suspended remote actor is a second thing to check alongside the domain.
  Keeping both behind one predicate is what stops them diverging.
- The blocklist is no longer editable as text, so bulk edits (importing a large
  external list by hand) have to go through the dashboard. The audit's
  "Add All" covers the case that motivated it.

## Alternatives considered

- **Keep the setting and add the metadata in a JSON blob.** Rejected: it keeps
  the read-modify-write race, cannot be queried or indexed, and gives the
  blocklist a schema without giving it a table.
- **Delete the domain's content on block** (Mastodon's "purge"). Rejected by
  P1-D7: a block is frequently precautionary or mistaken, and deletion cannot
  be undone. Hiding gives the same result to readers and keeps the decision
  reversible. Purging stays available as a separate, explicit act if it is ever
  needed.
- **Stamp a `hidden_at` column on remote actors or on content rows when a
  domain is blocked.** Rejected for now: it has to be recomputed on block,
  unblock, federation-mode change and allowlist edit, and a missed recompute
  fails silently in both directions. See the performance note above for when to
  revisit it.
- **Silence and reject-media levels** alongside full blocks. Rejected for this
  stage by P1-D7 (full blocks only) and recorded in the backlog; each extra
  level multiplies the predicate and needs its own UI and semantics. Note that
  the input is already there when we want it: Mastodon's blocklist CSV carries
  a `severity` column that `blocklist_audit.ex:94` currently discards.
- **Send `Block` / `Undo(Block)` to the blocked instance.** Already rejected by
  P1-D1 and ADR 0026, for the same reason at instance scale.
- **Let members opt out of an instance block** (keep seeing a domain the site
  blocked). Rejected: an instance block is the site's decision about what it
  hosts and serves, and a per-member exception would keep the content in the
  database's public surfaces anyway.
