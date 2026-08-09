# 0000 — Use Architecture Decision Records

- **Status:** Accepted
- **Date:** 2026-08-09
- **Deciders:** Baudrate maintainers

## Context

Baudrate carries a large amount of non-obvious design rationale: federation
trust boundaries, a media proxy that exists purely for viewer privacy, a
fail-closed proxy trust model, a hand-rolled delivery queue instead of a job
library. Until now that rationale lived in three places:

- `CLAUDE.md` — a dense "Key Gotchas" list aimed at coding agents
- `doc/development.md` — a 2000-line reference of *what* the system does
- `CHANGELOG.md` — a record of *when* things changed

None of them records *why* a decision was made, what was rejected, and what it
would cost to reverse. A human developer joining the project can read all three
and still not know whether a constraint is load-bearing or incidental. That
matters most for the security invariants, where "simplifying" the code silently
removes a defence.

## Decision

Record significant architectural decisions as ADRs in `doc/adr/`, one Markdown
file per decision, numbered sequentially (`NNNN-kebab-case-title.md`).

Each ADR uses a lightweight [Nygard-style](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions)
template: **Status**, **Date**, **Context**, **Decision**, **Consequences**,
and — where a real alternative was on the table — **Alternatives considered**.

Rules:

1. **ADRs are immutable once accepted.** To change a decision, write a new ADR
   and set the old one's status to `Superseded by NNNN`.
2. **An ADR explains why.** Reference implementation details, do not duplicate
   them; `doc/development.md` remains the reference manual.
3. **Write an ADR when** a decision is expensive to reverse, constrains future
   work, encodes a security invariant, or would otherwise be "simplified" away
   by someone who does not know the history.
4. Do not write an ADR for routine feature work, library version bumps, or
   anything already fully explained by the code.

ADRs 0001–0021 were written retroactively on 2026-08-09, reconstructing
decisions already embodied in the code as of v1.12.0. Their `Date` fields give
the approximate date the decision took effect where it is known.

## Consequences

- New contributors have one place to learn the load-bearing constraints.
- Reviewers can point at an ADR instead of re-arguing a settled question.
- The `CLAUDE.md` gotchas list can shrink to pointers over time.
- Cost: each significant change now carries a small documentation obligation,
  and retroactive ADRs may under-state alternatives that were never written
  down at the time.

## Alternatives considered

- **Keep everything in `doc/development.md`.** Rejected: it documents current
  state, and appending rationale to it makes an already long document longer
  without making the rationale findable or dated.
- **Rely on git history and commit messages.** Rejected: rationale is
  scattered across hundreds of commits and is not discoverable by topic.
