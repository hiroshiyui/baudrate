# 0071 — A direct message stays between the two people in it

- **Status:** Accepted
- **Date:** 2026-09-23
- **Deciders:** Baudrate maintainers
- **Related:** extends the rule the direct-message features already follow —
  never screened ([0065](0065-what-waits-for-review-is-not-content-yet.md)
  decision 12), exported only by their sender
  ([0023](0023-data-export-threat-model.md)), reported one message at a time;
  never cached on a device ([0059](0059-the-service-worker-caches-the-shell-and-never-content.md));
  images described as [0061](0061-an-image-description-is-not-a-form-field.md)
  describes them; uploads rationed as new accounts are
  ([0064](0064-a-new-account-is-slowed-down-not-shut-out.md)).

## Context

Phase 6D asks for three things in direct messages: a web push when one
arrives, image attachments, and search across one's own conversations. Each
of them is a way a private message could leave the conversation:

- **Push** passes through the browser vendor's push service. The payload is
  encrypted there, but a phone shows it on the lock screen to whoever holds
  it. And push in Baudrate has only ever existed as a side effect of a row on
  `/notifications`, whose duplicate check would also collapse every message
  from one sender into a single row.
- **Every upload is a public static file.** Anything under
  `priv/static/uploads/` is served by `Plug.Static` and by nginx's
  `/uploads/` alias, with `Cache-Control: public`; the only protection is a
  random name. An image attached to a direct message cannot work that way. A
  federated attachment would need a URL that another server can fetch
  without signing in — which is a public link, however long.
- **`Content.Search` also backs the unauthenticated `/ap/search`**, so
  message search in the same module would be one mistaken option away from a
  public endpoint.

## Decision

1. **A push names the sender and carries no text,** and a direct message
   makes **no row on `/notifications`**. The Messages badge is its notice;
   the push, if wanted, is the only other one.
   `WebPush.deliver_direct_message/3` sends "New message from …" in the
   recipient's language with an empty body, tagged per conversation so a
   burst replaces itself. Nothing is pushed for a muted or blocked sender, or
   when the member has turned direct-message pushes off (`"direct_message"`,
   a push-only preference key that is not a notification type).
2. **Images are private files.** They live in `uploads/dm_images`, a 0700
   directory, and are read only through `/messages/images/:id`
   (`DmImageController`), which checks every request: a participant in the
   conversation, the uploader of an image not yet sent, or a member holding
   `moderator.sanction_user` looking at a message an **open report** names.
   Everything else is the same 404. The filename never reaches a client, and
   direct paths are refused twice more — by a plug in front of `Plug.Static`
   and by nginx. Responses are `private, no-store`.
3. **Images travel only between members of this instance.** A conversation
   with an account on another server offers no upload, and
   `Messaging.create_message/3` refuses `image_ids` there
   (`:dm_images_local_only`). Text messages to other servers are unaffected.
4. **An image may be sent on its own.** A message with at least one image may
   have empty text.
5. **Uploads are rationed before they are processed.** 20 an hour (3 for an
   account still under the new-account limits) and 60 a day per member, at
   most 4 unsent at once, taken in `Messaging.create_dm_image/2` before the
   file is decoded — the processing and the disk the backup carries are what
   is being rationed. Viewing is limited to 300 per five minutes.
6. **Search reaches only the member's own conversations and lives in
   `Messaging`,** never in `Content.Search`, `/search` or `/ap/search`. It
   leaves out deleted messages and senders the member blocked or muted.
7. **A deleted message takes its images and its link preview with it.** The
   rows and files go with the soft delete; unsent uploads are swept after 24
   hours.

## Alternatives considered

- **A preview in the push.** What most chat apps do, and exactly the text
  that should not be on a lock screen.
- **A notification row for each message.** A second list of the same
  messages to read and clear, and a dedup index that would have collapsed
  them by sender.
- **A long unguessable URL for recipients on other servers**, as Mastodon
  does. It works without signing in, so anyone it reaches — a forwarded
  message, a server's cache, a log — can open the image. That is a public
  link with a long name.
- **Public uploads with random names,** like post images. The same thing
  again, on this instance.
- **Message search in `Content.Search`.** Rejected for the reason in the
  Context.

## Consequences

- A member cannot send an image to someone on Mastodon. The composer does
  not offer it, and the refusal says why.
- Operators must re-apply the nginx role once for the deny rule; until then
  the 0700 directory and the unexposed filenames are what protect the files.
- A moderator can see the image in a reported message and, as before, only
  that message's text — never the rest of the conversation.
- Only a member's **own** sent images are in their export; received ones are
  somebody else's data (0023).

## Acceptance gate

`test/baudrate/messaging/dm_privacy_test.exs`:

- the push payload has an empty body and names the sender, no notification
  row is created, and a muted sender or a switched-off preference pushes
  nothing;
- the image route answers both participants and an unsent upload's owner,
  and a moderator only with an open report; a guest, a stranger and a
  moderator without a report get 404; `/uploads/dm_images/…` is 404; the
  conversation page never renders the filename; deleting the message
  removes the row and the file;
- a conversation with another server refuses images;
- the hourly limit and the cap on unsent uploads refuse **without calling the
  image processor**;
- search finds only one's own messages, skips deleted ones, treats `%` and
  `_` literally, and nothing of it reaches the site search or `/ap/search`.
