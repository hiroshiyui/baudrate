# 0052 — A content warning is a field, not a prefix

- **Status:** Accepted
- **Date:** 2026-09-20
- **Deciders:** Baudrate maintainers
- **Related:** the media half applies
  [0006](0006-media-proxy-no-third-party-subresources.md) (no page emits a
  subresource from a host we do not control) and
  [0045](0045-the-video-player-loads-on-a-click.md) (the one embed loads on a
  click). Fields cast from user input follow
  [0049](0049-user-facing-changesets-are-allow-lists.md); the collapse control
  is named under [0018](0018-semantic-ids-and-classes-for-accessibility.md)'s
  rule about content blockers. Fifth stage of Phase 3 (federation reach).

## Context

An inbound object marked `sensitive` with a `summary` had the two glued
together on ingest:

```elixir
"[CW: #{summary}]\n\n#{body}"
```

That is a one-way conversion, and it loses the only thing that mattered. Once
the warning is inside the body, it is no longer a warning — it is the first
line of the text it was supposed to stand in front of. So:

- nothing could render the content collapsed, because nothing could tell where
  the warning ended and the post began;
- nothing could publish the warning back out, so a reply to a sensitive post
  left this instance unmarked;
- **the reader was shown the content anyway**, with a label above it. A content
  warning that displays the content is not a content warning.

It also existed twice, in `InboxHandler` and `ObjectResolver`, which is the
usual sign that something is a rule rather than a detail.

There is a second problem in the same field, in the other direction.
`ObjectBuilder.article_object/1` set `summary` to a 500-character **excerpt**
of the body. That is a defensible reading of AS2 for an `Article` — and it is
wrong in practice, because Mastodon maps `summary` to `spoiler_text` for every
object type it ingests. Every Baudrate article has therefore been arriving on
Mastodon hidden behind a "content warning" that was its own opening paragraph.

And a third, smaller one: video and audio attachments were **dropped**. Safe,
and it meant a post whose whole point was a video arrived looking empty.

## Decision

1. **`summary` and `sensitive` are columns**, on `articles`, `comments`,
   `timeline_items` and `timeline_item_replies`. The body is stored as the
   author wrote it.

2. **The rules live in one module.** `Baudrate.Content.ContentWarning` is
   called by every changeset that casts the pair, because four schemas
   accepting them from three directions is four chances to disagree, and a
   renderer must not have to know which table a row came from:

   - an empty warning is `nil`, never `""` — a form submits `""` for an
     untouched field, so this is the common case, and without it "has a
     warning" has two answers;
   - **text implies the flag**: a peer that sends a `summary` and forgets
     `sensitive` meant to warn somebody, and honouring the text is the reading
     that fails safe. The converse does not hold — `sensitive` with no text is
     a post marked sensitive with no reason given, which renders as the
     generic warning;
   - it is bounded at 512 characters. A warning is a label, not a post: one
     nobody can read past is not a warning. It is also a remote-controlled
     string reaching a column, so it needs an explicit bound like every other.

3. **`summary` outbound is the content warning and nothing else.** The excerpt
   is gone rather than moved: `name` already carries the title and `content`
   the body, so it told a reader nothing they could not already see.

4. **Rows written before this keep their `[CW: …]` prefix.** No rewrite. The
   prefix sits inside sanitized HTML and parsing it back out would be guessing
   where the warning ends. They are ordinary bodies now and age out.

5. **The collapse is a `<details>` element**, not a button and a hook. It is
   keyboard-operable, announced correctly by screen readers, and works with
   scripting off — and the whole point of a content warning is that it holds
   when something else has gone wrong. The classes are `content-warning`,
   `content-warning-summary`, `content-warning-body`: none of them contains a
   word a cosmetic-filter list targets, because a warning hidden by a content
   blocker would show the content it was standing in front of (0018, and the
   `#policy-accept` incident behind that rule).

6. **Video and audio render as a link to the original.** They cannot be
   proxied — that would mean this instance downloading and re-serving
   arbitrarily large files — and they must not be embedded, which is the
   hotlink `Media.Proxy` exists to prevent. A link contacts nobody until the
   reader follows it, the same bargain as the click-to-load video player
   (0045). `AttachmentExtractor.playable?/1` is the one predicate a renderer
   branches on.

7. **A warning is optional in every local composer** — articles (new and
   edit), comments and timeline replies — and is an allow-listed field like
   any other (0049). `sensitive` is derived, never posted.

## Alternatives considered

- **Keep the prefix and parse it out at render time.** Guessing where a
  warning ends, on content a peer wrote, for every render. It would also
  re-warn a post whose body legitimately begins "[CW: …]".
- **Rewrite the existing rows.** Same guess, done once and destructively. The
  rows are readable as they are; decision 4 costs nothing and cannot corrupt
  anything.
- **Keep the excerpt in `summary` and add a separate warning field.** There is
  no separate field — `summary` *is* where the fediverse puts a content
  warning, so keeping the excerpt there means never being able to send one.
- **Proxy video through `Media.Proxy`.** The proxy re-encodes images to WebP
  and caches them; the same treatment for video is a transcoding pipeline and
  a disk budget nobody asked for. The link is honest about what it is.
- **A JavaScript toggle instead of `<details>`.** More control over the
  animation, and it fails open: with a hook that did not load, the content is
  simply visible. Wrong failure direction for this.
- **Translate the media link label.** It is baked into stored HTML at ingest
  time, so it cannot follow the reader's locale the way a template can. The
  peer's own `name` is used when there is one; the fallback is a generic
  English noun rather than a lie about being localised.

## Consequences

- Articles published from here no longer carry a `summary` unless the author
  wrote one, so they stop appearing collapsed on Mastodon. That is the fix,
  and it is a visible change to how existing content renders elsewhere.
- Four tables gained two columns. A fifth surface that carries a warning has
  to call `ContentWarning.validate/1` and appear in the gate.
- `Publisher.build_create_comment/2` now uses `ObjectBuilder.comment_object/1`
  rather than building its own Note. The duplicate is what made mentions
  (0051) and then content warnings a thing to remember twice; it is gone.
- Timeline `attachments` rows now hold two kinds of thing, told apart by
  `media_type`. A renderer that forgets to branch will try to display a video
  as an image — hence `playable?/1` and the gate.
- The generic warning ("Sensitive content") and its "Show" affordance are
  translated in zh_TW and ja_JP. The machine merge produced plausible and
  wrong text for all three new strings — "Sensitive content" came back as
  *"recent posts"* — which is the hazard `CLAUDE.md` records, met in the wild.

## Acceptance gate

`test/baudrate/federation/content_warning_test.exs`. It checks the shared
rules on all four schemas at once, that an inbound warning is stored **and the
body is not touched**, that `summary` outbound is the warning and nothing
else, that what this instance publishes is what it would store if a peer sent
it back, and that a video attachment becomes a link rather than an `<img>` or
a `<video>`. A new surface that carries a warning belongs in it.
