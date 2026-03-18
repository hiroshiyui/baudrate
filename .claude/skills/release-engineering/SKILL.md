---
name: release-engineering
description: Manage the full software release process, including version bumps, changelogs, Git tags, and GitHub releases.
---

When performing release engineering, always follow these steps:

1. **Determine the release type** — review all unreleased commits since the last tag and classify the release as `major`, `minor`, or `patch` following [Semantic Versioning](https://semver.org/). Present the recommendation to the user and confirm before proceeding.

2. **Update the version** — bump the `version` field in `mix.exs` to match the new release version.

3. **Update `CHANGELOG.md`** — add a new version entry at the top following the [Keep a Changelog](https://keepachangelog.com/) format. Group changes under `Added`, `Changed`, `Fixed`, `Removed`, or `Security` as appropriate. Include all notable changes since the previous release.

4. **Commit the release** — stage `mix.exs` and `CHANGELOG.md` together and commit with the message `chore: release vX.Y.Z`.

5. **Tag the release** — create an annotated Git tag (e.g., `git tag -a v1.2.3 -m "v1.2.3"`) and push it to the remote (`git push --tags`).

6. **Create a GitHub release** — use `gh release create vX.Y.Z` with the corresponding `CHANGELOG.md` section as the release body.
