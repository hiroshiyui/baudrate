---
name: docs-engineering
description: Audit and update all project documentation (README, CLAUDE.md, doc/, ADRs, the spec index, moduledocs) against the code; remove finished TODOs; keep the docs compact.
---

1. **Audit against the code**, without exception: `README.md` (features,
   prerequisites, acknowledgements); `CLAUDE.md`; `doc/gotchas.md`; `doc/development.md`,
   `sysop.md`, `api.md`, `troubleshooting.md`, `TODOs.md`; `doc/baudrate-spec.md`;
   `doc/adr/`; `@moduledoc`/`@doc` of changed or related modules.
2. **Fix** what is stale, incomplete or inconsistent.
   - **Keep context small.** `CLAUDE.md` is loaded into every session: one or two lines
     per rule naming the function, ADR and gate. The long form (incident, bug shape,
     why the simplification is wrong) goes in `doc/gotchas.md`, never back into
     `CLAUDE.md`. Say a thing once and point to it; do not copy between docs.
3. **Remove finished items** from `doc/TODOs.md` (a short note first if warranted).
4. **ADRs** (`doc/adr/README.md`, process in `0000-…`):
   - They record *why* (context, decision, rejected alternatives, consequences);
     implementation detail stays in `doc/development.md`.
   - Write one when a decision is expensive to reverse, constrains later work, encodes
     a security or privacy invariant, or would plausibly be "simplified" away. Not for
     routine features or bumps.
   - Accepted ADRs are immutable except the Status line; supersede with a new number
     and update the index row (`adr_index_test.exs`).
   - A gotcha that explains a *why* belongs in an ADR, with the gotcha a pointer.
   - Code that no longer matches an accepted ADR is a regression or a silent decision
     needing a superseding ADR; say which.
4a. **The spec index** (`doc/baudrate-spec.md`): invariant → record → enforcement →
   gate, and nothing else (*why* goes in the ADR, *how* in `development.md`). Code wins
   over record, record over row. `test/doc/spec_index_test.exs` checks rows per ADR,
   test files, functions and arities, and ADR-declared gates; run it. It cannot check
   truth, so read the record. A new ADR needs rows; an invariant with no gate goes in
   **Rules with no automated gate** with an honest reason; never invent a gate.
5. **Commit** by topic.
