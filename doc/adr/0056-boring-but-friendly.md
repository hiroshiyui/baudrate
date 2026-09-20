# 0056 — Boring but friendly

- **Status:** Accepted
- **Date:** 2026-09-20
- **Deciders:** Baudrate maintainers
- **Related:** the premise behind
  [0054](0054-attention-follows-the-board-not-a-ranking.md) and
  [0055](0055-unanswered-is-a-river-and-tags-is-a-ranking.md), and the reason
  the safety and privacy records — [0006](0006-media-proxy-no-third-party-subresources.md),
  [0026](0026-blocks-stop-interaction-locally.md),
  [0029](0029-sanctions-are-rows-with-an-explicit-end.md),
  [0030](0030-domain-blocks-are-rows-and-hiding-is-reversible.md),
  [0045](0045-the-video-player-loads-on-a-click.md),
  [0048](0048-a-poll-records-who-voted-and-nothing-reads-it-back.md) — are load
  bearing rather than decoration. States no new rule of its own; it names the
  one the others are instances of.

## Context

The aim, in the operator's words on 2026-09-20:

> **a boring but friendly environment for online discussion.**

Several decisions already on file are instances of this, and each was argued
from first principles when it came up: no ranking and no river (0054), no
`/unanswered` and no tag index (0055), no third-party subresource on any page
(0006, 0045), a poll that records a voter and never reads them back (0048),
blocks and sanctions that stop interaction without deleting anyone (0026,
0029, 0030).

Deriving the same answer five times is a sign the premise is missing rather
than the answers being hard. It also failed once: 0054 forbade the river and
then carved out `/unanswered` in its own decision 5, because that page looked
like the opposite of the thing being refused. A premise stated once is what
catches an exception written into the rule itself.

### What each word is doing

**Boring.** The site does not compete for attention. It has no ranking, no
river, no karma, no badges, no streaks, no "N people are reading this", no
infinite scroll, and no notification designed to pull back someone who did not
ask to be pulled. Boring is not the absence of effort — it is where the effort
went. A forum that is exciting to *open* is usually exciting because somebody
is fighting in it, and the machinery that makes a site exciting to open is the
same machinery that decides a fight is the most important thing today.

**Friendly.** The other half, and it is not implied by the first: a site can
be perfectly calm and still hostile, by leaking its readers to third parties,
by making abuse expensive to report, or by treating a moderation decision as
something that happens to someone rather than something they are told. The
safety and privacy records are that half, and none of them is ornamental.

**For discussion.** The unit is a conversation in a board, not a post in a
feed. That is 0054's whole content, and it is why the board list is the
discovery surface.

The two halves need each other. Boring without friendly is a dead forum.
Friendly without boring is a site that has to *keep* people, and the reliable
way to keep people is a fight.

## Decision

Baudrate aims to be a boring but friendly environment for online discussion.
In practice that is four questions to ask of any proposed feature, and one
thing the answer may never be used for.

1. **Does it decide for the reader what to look at?** Then no. Ranking,
   rivers, "recommended", "you might like", a front page that changes by
   itself (0054, 0055).

2. **Does it measure a person or their work against other people's and show
   them the number?** Then no. Karma, reputation, leaderboards, badges,
   streaks, post counts on a profile, "top contributor". A number that
   compares people changes what they write, and the cost falls on the posts
   never made.

3. **Does it manufacture urgency the reader did not ask for?** Then no.
   "Trending now", countdowns, "3 people are typing", re-engagement pushes,
   anything whose purpose is the return visit rather than the thing returned
   to.

4. **Does being here cost the reader something they did not agree to?** Then
   no. Third-party requests, tracking, media that loads itself, a control that
   a content blocker will hide (the `#policy-accept` lesson), a preference
   that resets itself.

5. **"Boring" is never an argument against** safety work, accessibility,
   correctness, performance, federation reach, or clearer writing. Those make
   the site *more* boring in the sense meant here: they remove surprises. Anyone
   citing this record to refuse them has it backwards.

## Alternatives considered

- **Say nothing and keep deciding case by case.** What has been happening.
  It works, at the cost of re-arguing the premise every time, and it already
  let one exception through into an accepted record (0055 fixes it).
- **"Calm", "healthy", "quiet", "humane".** All nicer words, and all of them
  invite the reply *"of course we want it healthy — and engaging"*. **Boring**
  is the only one that admits the cost up front, which is exactly why it is
  the useful word. A principle that costs nothing decides nothing.
- **Pair it with a growth target.** Rejected: 0054 already records that growth
  is probably slower and that this is the decision rather than an oversight in
  it. A target would reopen every question this record closes, on a schedule.
- **Write it as a rule with a gate.** There is nothing to check. Every one of
  the four questions is a judgement, which is why this record's job is to be
  *read*, not to fail a build. Its consequences are gated where they can be —
  0054 and 0055 both have tests.

## Consequences

- **Some requests are answered "no, and not because it is hard."** That is a
  worse answer to receive than a technical one, and it is the honest one. This
  record exists so the refusal can be short and does not have to be personal.
- **Growth is probably slower,** as 0054 already recorded. A front-page river
  is the standard retention hook; so are streaks and karma. All of them are
  given up together, and for the same reason.
- **This record has no acceptance gate and cannot have one.**
  `doc/baudrate-spec.md` lists it among the rules review has to catch, with
  that reason, rather than pretending otherwise.
- **It is a premise, not a veto.** Decision 5 is there because a principle
  this broad is easy to reach for when the real objection is effort, and a
  record used that way would be worse than no record.
- **It is quotable, which is the point.** "A boring but friendly environment
  for online discussion" fits in an issue comment, a README and a refusal, and
  a principle that has to be paraphrased to be used does not get used.

## Acceptance gate

None, and this one is deliberate rather than an omission — see decision 4
under Alternatives. Nothing can test whether a feature manufactures urgency or
compares people to each other; that is why the four questions are written as
questions for a reviewer.

What *is* gated are the two records that apply it:
`test/baudrate_web/no_content_ranking_test.exs` for 0054 and 0055, plus
`no_hotlink_test.exs` for the privacy half. `doc/baudrate-spec.md` carries
this record in the table of rules with no automated gate.
