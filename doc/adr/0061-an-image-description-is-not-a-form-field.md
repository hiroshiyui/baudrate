# 0061 — An image description is not a form field

- **Status:** Accepted
- **Date:** 2026-09-22
- **Deciders:** Baudrate maintainers
- **Related:** shipped as the second half of the same stage as
  [0060](0060-an-edit-is-kept-and-the-history-is-public.md); the accessibility
  rules it serves are [0018](0018-semantic-ids-and-classes-for-accessibility.md)'s;
  the refusal to derive a description from a service is
  [0006](0006-media-proxy-no-third-party-subresources.md)'s rule applied to a
  new kind of request; the field it federates under sits beside the content
  warning of [0052](0052-a-content-warning-is-a-field-not-a-prefix.md). Part of
  6A, alongside 0060, in Phase 6 (member depth).

## Context

Images have been uploadable on articles, comments and timeline replies since
early on, and every gallery rendered the same alt text: `Image 1`, `Image 2`.
That is a placeholder, not a description — it tells a reader using a screen
reader that an image exists and nothing whatever about it, on a site whose
whole subject is what people have to say.

Two things made it worse than an omission:

- **A peer's description was being fetched and then thrown away.**
  `AttachmentExtractor` already returned the attachment's `name`, and
  `Images.fetch_and_store_one/3` dropped it, because no column existed to put
  it in. Somebody on another instance had done the work and we discarded it,
  then rendered `Image 2` over their words.
- **Nothing we published carried one.** Every image this instance federated
  arrived on Mastodon undescribed, whatever the uploader would have written.

The difficulty is not the column. It is **where the input lives**. Uploads are
`auto_upload: true` with a `progress:` callback, so the image row is inserted
the moment the upload completes — before the composer is ever submitted. A
description typed into the composer form would therefore be a form field
describing a row that already exists, and LiveView patches every input back to
the value the server rendered on each `phx-change`. That is the documented trap
this codebase has hit four times: the current password on `/profile/password`,
the username and recovery code on `/password-reset`, the bio on `/admin/bots`,
and every poll option when the title was typed.

## Decision

**The description belongs to the image row, and the control writes to that row
directly.**

1. **One rule for three tables.** `Baudrate.Content.ImageAlt` owns
   `fields/0`, `validate/1`, `from_remote/1` and `describe/1`, bounded at 1 500
   characters; `article_images`, `comment_images` and
   `timeline_item_reply_images` each carry `alt` and each casts it through that
   module. Three tables with three private opinions is how the alt text and the
   federated `name` would come to disagree.

2. **An empty description is `nil`, never `""`.** In HTML `alt=""` is not
   "undescribed" — it means *decorative, announce nothing*, which for a
   photograph somebody chose to post is a false statement to the one reader who
   depends on it. It is also unrecoverable: once stored, `""` cannot be told
   from a deliberate choice, so nothing can ever ask again.

3. **The input is not a form field.** It carries **no `name` attribute**, so it
   never joins the form params; it sits in a `phx-update="ignore"` container, so
   the `phx-change` re-render caused by typing anywhere else cannot patch it
   back and erase what was written; and it saves itself against the existing row
   on `phx-blur` and a debounced `phx-keyup`, carrying `phx-value-id`. This is
   not a workaround for the LiveView trap — it sidesteps the question, because
   the row the description belongs to is already there.

4. **The link announces the image; the `<img>` does not.** A gallery image is
   always inside an `<a>`, so the accessible name goes on the link via
   `Helpers.image_link_label/2` and the image itself is `alt=""`. Text in both
   announced the same picture twice — "Image 2, link" followed by "Image 2" —
   which is the failure the placeholder alt text was already producing, doubled.

5. **It federates as the attachment `name`**, on all three attachment builders,
   and is **absent** rather than empty when nobody wrote one: an empty `name`
   would tell every receiver the image is decorative.

6. **A peer's `name` is kept**, stripped of tags and bounded at ingest through
   `from_remote/1`, and rendered as the description. It cost nothing to keep and
   we were already fetching it.

7. **Only the uploader may describe an image.** `Images.update_*_image_alt/3` is
   scoped to the owning user, and the field is not rendered for anyone else —
   an admin editing another member's article used to be shown a control that
   silently could not save, which is worse than no control.

## Alternatives rejected

- **A field in the composer form.** The obvious shape, and the one that breaks:
  the row exists before submission, so the value would be patched back on every
  keystroke elsewhere in the form. Working around that with `phx-update="ignore"`
  on a *form* input would then leave the params and the row disagreeing about
  which is authoritative.
- **`alt=""` for an undescribed image.** One less branch, and a lie told to
  exactly the reader who cannot check it — and, because `""` and "decorative"
  are the same string, one that can never be corrected afterwards.
- **The description in both the link and the `<img>`.** Reads as more
  accessible and is less: the same image is announced twice, which is the noise
  screen-reader users route around by turning things off.
- **Requiring a description before a post may be submitted.** It produces
  "image", "photo", "a" — worse than nothing, because it is indistinguishable
  from a real description — and it makes an accessibility feature into a thing
  that blames the member. It stays optional and the field stays visible.
- **Deriving a description automatically.** Either a third-party service, which
  ADR 0006 refuses and which would hand every uploaded image to somebody else,
  or a model this instance does not run and will not ship.

## Consequences

- **Three tables, three builders and three composers carry the same field.** A
  fourth kind of image would have to join all of them. Direct messages have no
  upload path at all, so they are not one.
- **Rows written before this keep NULL** and are deliberately not backfilled:
  nobody wrote a description, and inventing one would be the same lie as
  decision 2.
- **The description is written without the composer being submitted.** An image
  uploaded, described and then abandoned keeps a description nobody ever sees,
  until the 24-hour orphan sweep removes the row and the file with it. That is
  the cost of the row existing first, and it is the same cost the upload itself
  already had.
- **One surface still claims "decorative" when it means "undescribed", and it
  is named here rather than quietly fixed.** Images on an inbound *comment* or
  DM are not rows at all — `InboxHandler.append_attachment_images/2` appends
  them to `body_html` as inline `<img>` tags — and it emits `alt=""` when the
  peer sent no `name`, which decision 2 calls a lie. It cannot simply fall back
  to "Image N" the way the gallery does, because that string would be written
  into stored HTML in whatever locale the ingest process happened to be in and
  would stay that way for ever. Closing it properly means the attachments
  becoming rows, rendered at read time, which is a change to ingest and not a
  fallback string. Tracked in `doc/TODOs.md`.
- **`test/baudrate/content/image_alt_test.exs` is the acceptance gate**, with
  the federated half in
  [`object_builder_test.exs`](../../test/baudrate/federation/object_builder_test.exs)
  and the control's two load-bearing properties — no `name`, and the ignored
  container — in
  [`core_components_test.exs`](../../test/baudrate_web/components/core_components_test.exs).
