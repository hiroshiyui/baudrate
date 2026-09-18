# 0045 — The video player loads on a click, and nothing else is embedded

- **Status:** Accepted
- **Date:** 2026-09-19
- **Deciders:** Baudrate maintainers
- **Refines** [0006](0006-media-proxy-no-third-party-subresources.md). It does
  not reverse it: after this change a reader who does not click still fetches
  nothing from a host we do not control, which is what 0006 requires. What 0006
  did not say is what to do when a reader *wants* the third-party resource.

## Context

A YouTube link preview rendered `<iframe src="https://www.youtube-nocookie.com/embed/…">`
directly into the page, on article pages, comment threads and DM
conversations, and `router.ex` carried `frame-src https://www.youtube-nocookie.com`
to permit it. So opening a thread that happened to contain a YouTube link
disclosed the reader's IP address and User-Agent to a Google-operated host —
the outcome [0006](0006-media-proxy-no-third-party-subresources.md) exists to
prevent, and which `CLAUDE.md` states as an absolute rule.

It was not careless: `youtube-nocookie.com` withholds cookies until playback,
`referrerpolicy="strict-origin"` sent only our origin rather than the article
URL, and `loading="lazy"` deferred the request until the embed neared the
viewport. It was a considered trade, made for a real feature. It was simply
never written down, and nothing enforced its limits.

The deeper problem was the gate. `no_hotlink_test.exs` matched
`<img[^>]+src="(?:https?:)?//` and nothing else — so the acceptance test for
the project's strongest privacy invariant could not see `<iframe>`, `<script>`,
`<video>`, `<link rel=stylesheet>` or `url()` in CSS. The YouTube embed is one
deviation; a gate blind to every subresource except images is why there could
have been others, and why the next one — a Vimeo player, a Spotify card, a
Twitter embed — would have landed unchallenged.

## Decision

**1. The player loads on a click, never on render.** The server renders a
poster frame and a play button; a hook builds the `<iframe>` when the reader
presses it. A reader who scrolls past a video contacts nobody. A reader who
presses play has asked for the video, and gets it.

**2. The poster is local.** The thumbnail is the `image_path` the link-preview
fetcher already stored — it fetches OG images server-side, re-encodes them and
serves them from our own host, with no YouTube special case. So click-to-load
costs no new fetching machinery; the poster existed and was unused.

**3. The button says where the player comes from.** "Play “…”. The player loads
from YouTube." An informed click is the entire justification for treating this
differently from an automatic request, so the interface has to make it
informed, in every locale.

**4. Exactly one embed origin, enforced by a test.** `frame-src` admits
`https://www.youtube-nocookie.com` and nothing else, and
`no_hotlink_test.exs` asserts the directive matches exactly that. A second
origin cannot be added by editing the CSP; it fails the build, which forces the
decision to be made deliberately and written down.

**5. The gate covers subresources, not images.** It now matches `img`,
`iframe`, `script`, `source`, `video`, `audio`, `embed`, `track`, `object` and
`input` on `src`/`data`, `<link>` on `href` for the `rel` values that actually
fetch, and `url()` in CSS. `<a href>` is deliberately absent — navigation is
not a subresource — and so is `rel="alternate"`, which is metadata: a remote
article's `alternate` legitimately points at the `ap_id` on the host that
published it, and the browser never requests it.

## Alternatives considered

- **Leave it and record the exception in an ADR.** Honest, and it was the other
  serious option. Rejected because the trade is avoidable: the poster was
  already local, so the privacy cost bought nothing that click-to-load does not
  also deliver.
- **Remove the embed entirely.** Restores 0006 with no mechanism, and loses a
  feature that makes video links usable. Click-to-load keeps both.
- **Proxy the video through our own host.** The media proxy re-encodes images;
  video is a different order of bandwidth and storage, and it would make this
  instance a redistributor of other people's video.
- **A per-viewer preference** ("always load embeds"). More surface, and a
  stored preference that silently re-enables third-party requests is the thing
  0006 is about. Can be revisited if anyone asks.

## Consequences

- One extra click to watch a video. That is the cost, and it is the point.
- The player cannot be seen by the HTML gate, because it does not exist until
  the click. CSP `frame-src` is what constrains it at runtime, which is why
  decision 4 pins that directive under test.
- `phx-update="ignore"` on the player container is load-bearing: without it a
  LiveView patch — a new comment arriving over PubSub — would replace the
  running player with the poster again.
- The preview component now needs a unique `id` per rendered page for its hook.
  Link previews are deduplicated by URL, so two comments linking the same video
  share one row and cannot derive one; callers pass a scoped id.
- Any future embed is a new ADR, not a CSP edit.

## Acceptance gate

`test/baudrate_web/no_hotlink_test.exs` — that no page renders a third-party
subresource of any kind, that the YouTube preview renders a local poster and no
player, and that `frame-src` admits exactly one origin.
