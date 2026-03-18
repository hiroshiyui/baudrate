---
name: commit-and-push
description: Stage, commit, and push changes to the remote repository with a well-formed commit message.
---

When committing and pushing changes, always follow these steps:

1. **Stage** all relevant changes with `git add`. Be deliberate — stage only files related to the current topic. Never blindly stage everything with `git add -A` if unrelated changes are present.

2. **Commit** with a clear, concise message following the [Conventional Commits](https://www.conventionalcommits.org/) standard (e.g., `feat(bots): add favicon retry logic`). The message should explain *why* the change was made, not just *what* changed.

3. **Push** the committed changes to the current branch on the remote repository.

4. **Verify** that the push succeeded and the remote is in sync with the local branch.
