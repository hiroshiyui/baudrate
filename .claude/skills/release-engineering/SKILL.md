---
name: release-engineering
description: Manage the full software release process, including version bumps, changelogs, Git tags, and GitHub releases.
---

When performing release engineering, always follow these steps:

0. **Start from `current`** — releases are prepared on the `current` branch; `main` is never committed to directly. Verify `git branch --show-current` is `current`, the working tree is clean, and `current` is pushed. If `main` has commits that `current` lacks (`git log current..main`), stop and ask the user.

0a. **Audit the documentation before anything else** — run the `docs-engineering` skill and commit what it finds, *before* the version is decided. Its commits then land inside the release and inside the tag. Run it after the release and the tag permanently describes the release before it: v1.27.0 shipped with `mix.exs` understating its own Elixir requirement, a manual-install example pinned to `v1.26.0` (the release whose deploy model ADR 0037 had just reversed), a NodeInfo sample nineteen versions behind, and a project tree missing `media/` — the machinery behind the no-hotlink invariant. Two things follow from running it here:
   - **What it finds that is not documentation is a change like any other.** It gets a `CHANGELOG.md` entry in step 4 and may move the version decision in step 1 — not a follow-up commit after the tag. The v1.27.0 audit found `mix.exs` declaring `elixir: "~> 1.15"` while a non-optional dependency requires `~> 1.17`, so no one on 1.15 could build at all; that is project metadata belonging under `Fixed`.
   - **Re-check step 0 afterwards.** `docs-engineering` ends with commits of its own, so confirm the working tree is clean and `current` is pushed again before continuing.

1. **Determine the release type** — review all unreleased commits since the last tag and classify the release as `major`, `minor`, or `patch` following [Semantic Versioning](https://semver.org/). Present the recommendation to the user and confirm before proceeding.

2. **Run the full test suite** — run all tests with 4 partitions and seed 9527 and wait for all to pass before proceeding. **Do not continue if any test fails.**
   ```bash
   for p in 1 2 3 4; do MIX_TEST_PARTITION=$p mix test --partitions 4 --seed 9527 & done; wait
   ```

3. **Update the version** — bump the `version` field in `mix.exs` to match the new release version.

4. **Update `CHANGELOG.md`** — add a new version entry at the top following the [Keep a Changelog](https://keepachangelog.com/) format. Group changes under `Added`, `Changed`, `Fixed`, `Removed`, or `Security` as appropriate. Include all notable changes since the previous release.

5. **Commit the release** — on `current`, stage `mix.exs` and `CHANGELOG.md` together, commit with the message `chore: release vX.Y.Z`, and push `current`.

5a. **Merge into `main`** — fast-forward only, then return to `current`:
   ```bash
   git switch main && git merge --ff-only current && git push origin main && git switch current
   ```
   If the fast-forward fails, `main` was modified out of band — stop and ask the user; never force-push or create a merge commit on `main` to get past it.

6. **Tag the release** — create an annotated Git tag (e.g., `git tag -a v1.2.3 -m "v1.2.3"`) and push it to the remote (`git push --tags`).

7. **Create a GitHub release** — use `gh release create vX.Y.Z` with the corresponding `CHANGELOG.md` section as the release body.

8. **Check the release build** — publishing the GitHub release starts `.github/workflows/release.yml` (ADR 0036), which builds, smoke-tests and attests the production release and attaches `baudrate-X.Y.Z-debian12-x86_64.tar.gz` to it. Watch it (`gh run list --workflow release.yml`, then `gh run watch <id>`). The deploy builds on the server and does not need the tarball (ADR 0037), so a failure here does not block deploying — but it means the release could not start in CI, so read it before deploying anyway. A rebuild for the same tag is a re-run of that workflow run.
