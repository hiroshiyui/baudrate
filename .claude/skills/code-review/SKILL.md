---
name: code-review
description: Project-wide full-scope code review — correctness, the type checker, security, tests, locales, docs, code smells, a11y and conventions — then report by severity and fix Critical/Major issues.
---

Review the **whole project**, not just recent changes. Read `CLAUDE.md` (the rules;
long form in `doc/gotchas.md`) and `doc/TODOs.md` first, skim `lib/`, and prioritise
public endpoints, the federation boundary, auth, content handling and admin routes.
Every rule in `CLAUDE.md` is a check; the list below is what reviews most often miss.

## 1. Correctness
- Logic and pattern-match errors, missing `nil`/`{:error, _}` handling, error shapes a
  callee really returns (`create_article/3` fails as a Multi 4-tuple).
- Ecto: missing preloads, N+1, counter updates without locks or `Multi`, ILIKE without
  `sanitize_like/1`, soft-deleted rows (`deleted_at`) leaking into queries.
- LiveView: a `handle_info` catch-all; `handle_event` re-checks authorization;
  mount/handle_params races; form state per the Forms rule.
- State transitions that can go backwards (re-sending delivered work), substring
  matches where exact matches were meant, visibility leaks when a row loses its board.
- Pagination through `Baudrate.Pagination`; ordering with an `id` tiebreaker.

## 2. The type checker (Elixir 1.20 and Dialyzer)
Every type warning is a finding. Delete what it proves unreachable (catch-alls, `nil`
clauses, error branches a callee never returns, redundant guards and `|| []`), pin
bitstring sizes, remove unused `require`s. Never widen a type, add a dead clause or
suppress. When it calls a correct branch unreachable, the spec is wrong: fix the spec.
`.dialyzer_ignore.exs` holds only opaque-type and compile-flag notices.

## 3. Security
Apply the `security-audit` checklist at review depth: input and output encoding, SSRF
through `Federation.HTTPClient`, the federation origin and gate rules, `on_mount`
hooks and sudo, `ensure_can_interact/1` on every posting path, secrets in vaults,
uploads, rate limits, OWASP Top 10.

## 4. Tests
Every public context function and LiveView action is tested (mirroring `lib/`);
negative paths for security-sensitive code; gates named in `CLAUDE.md` cover new
surfaces; deterministic (no `Process.sleep`, `id` tiebreakers, no shared state across
partitions); rate limiter sandboxed.

## 5. Locales
Apply `l10n-engineering` steps 1 and 4: no bare strings (including `aria-*`, flash,
feed text), `%{var}`, no raw identifiers shown, zh_TW and ja_JP complete, settled
terms, no orphans.

## 6. Docs
`@moduledoc`/`@doc` accurate; `CLAUDE.md`, `doc/gotchas.md`, `doc/development.md`,
`sysop.md`, `api.md`, README match the code; no finished TODOs; no commented-out code.

## 7. Code smells
Duplication; bloated functions and `with` chains; feature envy across contexts;
speculative generality; dead code, `IO.inspect`/`dbg`; one module per file; no
`:code.priv_dir/1` in module attributes; cache refresh after direct writes; integer
avatar sizes.

## 8. UI and a11y
Apply the `a11y-engineering` checklist at review depth: ADR 0018 anchors, landmarks,
names on icon-only controls, labelled fields with linked errors, focus handling, no
colour-only state, responsive layout, `@inner_content` and no `<Layouts.app>` wrapper.

## Report
**Critical:** security, data loss, auth bypass, secret exposure. **Major:** logic errors,
missing tests for observable behaviour, convention breaks that fail at runtime, a11y
barriers. **Minor:** style, docs, i18n gaps, cosmetic a11y, small smells. Each finding:
`file:line`, impact, concrete fix.

## Fix
Fix Critical and Major directly, sweep for each class found, and run the full suite
(seed 9527, 4 partitions) until it passes.
