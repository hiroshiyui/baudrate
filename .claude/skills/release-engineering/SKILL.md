---
name: release-engineering
description: Manage the full software release process, including version bumps, changelogs, Git tags, and GitHub releases.
---

When performing release engineering, always follow these steps:

0. **Start from `current`** — releases are prepared on the `current` branch; `main` is never committed to directly. Verify `git branch --show-current` is `current`, the working tree is clean, and `current` is pushed. If `main` has commits that `current` lacks (`git log current..main`), stop and ask the user.

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
