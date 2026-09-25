---
name: release-engineering
description: Run a release — pre-release docs/a11y/l10n audits, version decision, full tests, CHANGELOG and version bump, ff-merge to main, tag, GitHub release, release-build check.
---

0. **Start from `current`:** clean tree, pushed. If `git log current..main` shows
   anything, stop and ask.
   - **0a.** Run `docs-engineering` and commit its findings *before* deciding the
     version, so they land inside the tag (v1.27.0 shipped docs describing the release
     before it). A non-doc finding is a change like any other: it gets a CHANGELOG entry
     and may move the version.
   - **0b.** Run `a11y-engineering` over what the release changes; commit its fixes.
   - **0c.** Run `l10n-engineering`; commit its fixes.
   - Re-check step 0 afterwards.
1. **Decide major / minor / patch** (SemVer) from the unreleased commits; confirm with
   the user.
2. **Run every test.** The partitioned suite, then the browser suite (it is excluded
   by default; v1.33.0 shipped two stale browser tests that were never named):
   ```bash
   for p in 1 2 3 4; do MIX_TEST_PARTITION=$p mix test --partitions 4 --seed 9527 & done; wait
   rm -f priv/static/assets/{css,js}/*.gz priv/static/cache_manifest.json
   mix assets.build && mix test --include feature test/baudrate_web/features/
   ```
   Stop on any failure.
3. **Bump** `version` in `mix.exs`.
4. **CHANGELOG.md:** a new entry at the top (Keep a Changelog: Added, Changed, Fixed,
   Removed, Security).
5. **Commit** `mix.exs` + `CHANGELOG.md` on `current` as `chore: release vX.Y.Z`; push.
   - **5a.** `git switch main && git merge --ff-only current && git push origin main && git switch current`.
     If it is not a fast-forward, stop and ask; never force-push or merge-commit `main`.
6. **Tag:** `git tag -a vX.Y.Z -m "vX.Y.Z"`; `git push --tags`.
7. **GitHub release:** `gh release create vX.Y.Z` with the CHANGELOG section as the body.
8. **Check the release build** (`release.yml`, ADR 0036): `gh run list --workflow
   release.yml`, then watch it. The deploy builds on the server (ADR 0037) so a
   failure does not block it, but read it before deploying. Rebuild = re-run that run.
   The deploy itself waits for `elixir.yml` on the release commit and needs the user's
   confirmation.
