---
name: docs-engineering
description: Audit and update all project documentation to stay in sync with the current development status.
---

When performing documentation engineering, always follow these steps:

1. **Audit** all documentation against the current codebase and development status. The review scope must include — without exception:
   - `README.md` — features list, prerequisites, acknowledgements
   - `CLAUDE.md` — stack, architecture, key gotchas, project conventions
   - `doc/` — `development.md`, `sysop.md`, `api.md`, `troubleshooting.md`, `TODOs.md`
   - `@moduledoc` and `@doc` strings in changed or related modules

2. **Revise and update** any documentation that is stale, incomplete, or inconsistent with the current code. Ensure new features, removed dependencies, behavioral changes, and architectural decisions are reflected accurately.

3. **Remove completed items** from `doc/TODOs.md`. If a summary of completed work is warranted, add a brief note before removing the items.

4. **Commit** documentation changes in Git, grouped by topic. Do not mix unrelated documentation changes in a single commit.
