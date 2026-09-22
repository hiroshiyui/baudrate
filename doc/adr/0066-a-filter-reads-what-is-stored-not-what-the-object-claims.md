# 0066 — A filter reads what is stored, not what the object claims

- **Status:** Accepted
- **Date:** 2026-09-22
- **Deciders:** Baudrate maintainers
- **Amends** [0065](0065-what-waits-for-review-is-not-content-yet.md),
  decisions 8 (what a filter reads) and 13 (the routes remote content is
  screened on), both of which name less than the code has screened since
  v1.39.0. Everything else in 0065 stands — decision 12 included: direct
  messages are still never screened.
- **Related:** the security audit run before v1.39.0 was cut, which found
  every gap below in 5D's own code; a description is the attachment `name` of
  [0061](0061-an-image-description-is-not-a-form-field.md), and changing one
  now passes the sanction gate of
  [0029](0029-sanctions-are-rows-with-an-explicit-end.md); import by URL is
  the member-triggered fetch whose origin rules are
  [0046](0046-every-identity-claim-is-bound-to-the-host-that-can-prove-it.md)'s.

## Context

0065 decided what a filter is and where it runs, and said what it reads: a
post's text as a reader sees it and the hosts of its links (decision 8), and
remote content on four routes (decision 13). Those lists were written by
reading the posting paths forwards. The audit before the release read them
backwards — from every column a post fills and every page that shows one — and
found text reaching readers that no filter had seen:

- **Fields the list did not name.** A local post's poll options and its
  images' descriptions; a remote object's `source.content`, which the inbox
  falls back to when `content` is empty; and the names of a remote object's
  attachments (stored as image descriptions) and of its poll's options
  (`oneOf`/`anyOf`). Any of them carried a filtered word past every filter.
- **An edit nobody had counted as one.** A description saves itself against
  its row as it is typed (0061), so on a published post it can be changed
  without touching the post. Nothing screened the change, and nothing asked
  whether its author was silenced.
- **An exemption keyed on the wrong thing.** Decision 12 keeps filters out of
  direct messages, and the inbox applied that to `Update(Note)` by looking at
  the Update's addressing. But `handle_update_note/2` rewrites the *stored*
  comment its `ap_id` names. A peer could post a clean public reply, then send
  an `Update` addressed like a message that edited refused text into it.
- **A route the list did not have.** `ObjectResolver.resolve/1` — a member
  pasting a post's URL into `/search` — stores remote content without passing
  through the inbox, so no filter saw it. Nothing limited how often a member
  could make the server fetch an address of their choosing, either.

Each was fixed before the release, with a regression test. They are recorded
here, not only in the changelog, because they share a cause: each was a list
— of fields, of routes, of what makes an object private — and a list stays
right only until the thing it describes grows.

## Decision

1. **A filter reads everything of a post that is stored and shown**, not a
   list of fields somebody remembered. Locally that is the title, the content
   warning, the body as a reader sees it, the host of every link, the poll's
   options and the descriptions of the post's uploads — the last two passed
   to `ContentFilters.screen/2` as `:extra`, lazily, so they cost a query
   only when a filter exists. Remotely (`ContentFilters.screen_remote/2`) it
   is `name`, `summary`, `content` **and** `source.content`, and the `name` of
   every `attachment`, `oneOf` and `anyOf` entry. **A field added to what a
   post stores and shows is added to what a filter reads in the same
   change.** This replaces the list in 0065's decision 8; its normal form, and
   its rule that the body is matched as rendered, stand.
2. **Changing the description of a published or held image is an edit**
   (`Images.update_article_image_alt/3`, `update_comment_image_alt/3`,
   `ReplyImages.update_reply_image_alt/3`). It passes the sanction gate first
   and then the filters as an edit, judged by what it adds (0065, decisions 9
   and 10). A draft's upload is not published yet; it is screened with the
   post when the post is submitted.
3. **An exemption is decided by what the handler will write, never by what
   the incoming object says about itself.** A `Create(Note)` addressed as a
   message is left alone because it becomes a message. An `Update(Note)` is
   screened whatever its addressing, because it rewrites whatever stored row
   its `ap_id` names; the one left alone is an Update naming a message this
   instance holds, whose edits are never applied. The general form: when a
   handler acts on a stored row found by id, whatever exempts the activity
   has to be a fact about that row. The object's addressing and type are the
   sender's claims, and the sender is who the filter is there for.
4. **Import by URL is a route remote content arrives by**, and is screened as
   one. `ObjectResolver.resolve/1` refuses the import where the inbox would
   have dropped the object, and imports and reports it where the inbox would
   have reported it. A member may import 10 posts per 5 minutes
   (`RateLimits.check_remote_import/1`), because each import is an outbound
   fetch to an address the member chose. This adds a route to 0065's decision
   13.

## Alternatives rejected

- **Correcting 0065's lists in place.** It is accepted, and rewriting it
  would also erase the finding. A reader who sees only the corrected list
  learns nothing about how the first one went wrong, and writes the next
  list the same way.
- **Screening every `Update(Note)`, messages included.** It removes the
  exemption instead of keying it correctly. A match on a message would record
  that a private conversation matched — and a flag would copy it to staff —
  which is what 0065's decision 12 exists to prevent.
- **Screening a description only with its post.** Screening at submit checks
  the description once, and a control that saves on its own can replace it at
  any time afterwards.
- **Screening the stored row after the handler has written it.** That would
  read every field by construction, which is the property the lists lacked.
  But a drop has to happen before anything is written — refused content never
  reaches the database — so every handler would have to roll back its own
  write, and a flag would have to decide afterwards which of several rows it
  was about.

## Consequences

- **Nothing fails the build when a new stored field is not screened.** The
  corpus follows the schema by review, not by construction; its row in
  `doc/baudrate-spec.md` has no gate, and says so. The gate below holds one
  case per field the audit found, and a new field belongs in it with a case
  of its own.
- **Saving a description can be refused**, and the four pages that save one
  flash the refusal. A silenced member can no longer change one on a published
  post.
- **An import can be refused** with the same neutral sentence as a post, and a
  member importing quickly has to wait.
- **Screening a local post costs one query more for its descriptions**, and
  only when a filter for local content exists.
- **0065 still names the narrower lists.** Its Status points here, and
  `doc/development.md` (Content filters) is the reference for the full set.

## Acceptance gate

`test/baudrate/moderation/content_filter_test.exs` has a case for each field
in decision 1, for the Update addressed like a message and for a description
changed on a published post, each failing when its hole is put back. The
import is gated by `test/baudrate/federation/object_resolver_test.exs` and its
limit by `test/baudrate_web/live/search_live_test.exs`.
