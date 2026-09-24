## What and why

<!-- What this changes, and the reason. Link the issue or TODOs item. -->

## Checklist

- [ ] Branched from and targets `current` (never `main`)
- [ ] Commits are grouped by topic, with Conventional Commit messages
- [ ] Tests added or updated, mirroring `lib/`; the full suite passes with seed 9527 in 4 partitions
- [ ] Browser suite run, if templates, CSS or `assets/js/` changed
- [ ] Every new user-visible string uses `gettext()`, translated by hand in `zh_TW` and `ja_JP`; no fuzzy entries; `en` left blank
- [ ] New elements have semantic `id`/`class` and accessible names (ADR 0018)
- [ ] Docs updated (`doc/`, module docs); an ADR added for a decision that is expensive to reverse
- [ ] No acceptance gate named in `CLAUDE.md` or `doc/baudrate-spec.md` weakened — or the PR says why

## Security

<!-- Does this touch authentication, authorization, federation input, file
paths, uploads or rate limits? Say how it was checked. Vulnerabilities go by
email (SECURITY.md), not in a pull request. -->
