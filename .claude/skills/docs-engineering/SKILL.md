---
name: docs-engineering
description: Audit and update all project documentation to stay in sync with the current development status.
---

When performing documentation engineering, always follow these steps:

1. **Audit** all documentation against the current codebase and development status. The review scope must include — without exception:
   - `README.md` — features list, prerequisites, acknowledgements
   - `CLAUDE.md` — stack, architecture, key gotchas, project conventions. It is
     loaded into every coding session, so it stays **short**: one or two lines
     per rule, naming the function, ADR and gate test. The full text of a rule
     (the incident, the bug's shape, why the simplification is wrong) goes in
     `doc/gotchas.md`, never back into `CLAUDE.md`
   - `doc/` — `development.md`, `sysop.md`, `api.md`, `troubleshooting.md`, `TODOs.md`
   - `doc/baudrate-spec.md` — the conformance index (see step 4a)
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
   - **Cross-check against the gotchas** (`CLAUDE.md`, long form in `doc/gotchas.md`). A gotcha that explains a *why*
     (a trust boundary, a fail-closed choice, a deliberate non-obvious design)
     belongs in an ADR, with the gotcha reduced to a pointer. A gotcha that is
     purely a *how* stays where it is.
   - **Check for drift.** If the code no longer matches an `Accepted` ADR, that
     is either a regression to report or a decision that was silently changed and
     needs a superseding ADR — say which, do not quietly edit the old record.

4a. **Audit the conformance index** in
   [`doc/baudrate-spec.md`](../../../doc/baudrate-spec.md) — every invariant
   with the record that explains it, the code that enforces it, and the gate
   that fails if it breaks.

   - **It states no rules of its own.** Every row is a one-line summary plus
     pointers. Never let it become a fifth place an invariant is written: if a
     row starts explaining *why*, that belongs in the ADR, and if it starts
     explaining *how*, that belongs in `doc/development.md`.
   - **Precedence when things disagree:** the code wins over the record, and
     the record wins over the row. A row that contradicts the code is a bug in
     the index; a record that contradicts the code is a defect in one of them —
     say which, per step 4.
   - **`test/doc/spec_index_test.exs` is the gate.** It checks that every ADR
     has a row, that every named test file exists, that every named function
     exists at the arity given, and that a gate an ADR declares for itself
     appears in that ADR's rows. Run it; it is fast. What it cannot check is
     whether a summary is *true* — only reading the record does that, which is
     why this step exists at all.
   - **New ADR in this pass? It needs rows,** and the test will fail until it
     has them. An invariant with no automated gate gets a row in the
     **Rules with no automated gate** table, with an honest reason. Do not
     invent a plausible gate to fill the column: an index that claims coverage
     it does not have is worse than one that admits the hole. The 2026-09-19
     audit found eight real defects and most of them lived exactly where no
     gate did.
   - **Renamed a test or moved a function?** The index points at it. The gate
     catches the rename; only you can judge whether the *invariant* still holds.

5. **Commit** documentation changes in Git, grouped by topic. Do not mix unrelated documentation changes in a single commit.
