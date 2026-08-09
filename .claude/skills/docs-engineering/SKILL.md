---
name: docs-engineering
description: Audit and update all project documentation to stay in sync with the current development status.
---

When performing documentation engineering, always follow these steps:

1. **Audit** all documentation against the current codebase and development status. The review scope must include — without exception:
   - `README.md` — features list, prerequisites, acknowledgements
   - `CLAUDE.md` — stack, architecture, key gotchas, project conventions
   - `doc/` — `development.md`, `sysop.md`, `api.md`, `troubleshooting.md`, `TODOs.md`
   - `doc/adr/` — Architecture Decision Records (see step 4)
   - `@moduledoc` and `@doc` strings in changed or related modules

2. **Revise and update** any documentation that is stale, incomplete, or inconsistent with the current code. Ensure new features, removed dependencies, behavioral changes, and architectural decisions are reflected accurately.

3. **Remove completed items** from `doc/TODOs.md`. If a summary of completed work is warranted, add a brief note before removing the items.

4. **Audit the Architecture Decision Records** in `doc/adr/`. See
   [`doc/adr/README.md`](../../../doc/adr/README.md) for the index and
   [`doc/adr/0000-use-architecture-decision-records.md`](../../../doc/adr/0000-use-architecture-decision-records.md)
   for the process and template.

   - **ADRs record *why*, not *what*.** `doc/development.md` stays the reference
     manual; an ADR states the context, the decision, the alternatives that were
     rejected, and the consequences we now live with. Never duplicate
     implementation detail into an ADR — reference it.
   - **Write a new ADR when** a decision is expensive to reverse, constrains
     future work, encodes a security or privacy invariant, or would plausibly be
     "simplified" away by someone who does not know the history. Do **not** write
     one for routine feature work, dependency bumps, or anything the code already
     explains.
   - **ADRs are immutable once `Accepted`.** To change a decision, add a new ADR
     with the next free number and set the superseded one's status to
     `Superseded by NNNN`. Never rewrite an accepted record — only its `Status`
     line may change.
   - **Keep the index in sync.** Every new or superseded ADR updates the table in
     `doc/adr/README.md`.
   - **Cross-check against `CLAUDE.md` gotchas.** A gotcha that explains a *why*
     (a trust boundary, a fail-closed choice, a deliberate non-obvious design)
     belongs in an ADR, with the gotcha reduced to a pointer. A gotcha that is
     purely a *how* stays where it is.
   - **Check for drift.** If the code no longer matches an `Accepted` ADR, that
     is either a regression to report or a decision that was silently changed and
     needs a superseding ADR — say which, do not quietly edit the old record.

5. **Commit** documentation changes in Git, grouped by topic. Do not mix unrelated documentation changes in a single commit.
