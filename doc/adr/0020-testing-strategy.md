# 0020 — Deterministic, partitioned tests with a stubbable rate limiter

- **Status:** Accepted
- **Date:** Recorded retroactively 2026-08-09

## Context

A security-critical system is only as good as the suite that guards it, and a
suite is only useful if a failure means something. Three properties were
repeatedly at risk:

- **Determinism.** Async tests running concurrently across partitions surface
  ordering bugs — timestamps that collide, queries without a tiebreaker, shared
  ETS state. A test that passes in isolation and fails in partition 3 is worse
  than no test, because it trains people to re-run.
- **Global state.** The rate limiter is process-global ETS. A real limiter
  makes tests order-dependent: the 11th login test in a run fails.
- **Speed.** A suite nobody runs before committing does not protect anything.

## Decision

- **Always run the full suite with seed 9527 and 4 partitions:**

  ```bash
  for p in 1 2 3 4; do MIX_TEST_PARTITION=$p mix test --partitions 4 --seed 9527 & done; wait
  ```

  A fixed seed makes ordering reproducible; partitions keep the suite fast and
  keep concurrency bugs visible rather than hidden.

- **Test stability is a first-class requirement.** Tests must pass
  deterministically under concurrent partitioned execution, not just in
  isolation. Concretely: never `Process.sleep` for timestamp separation — set
  explicit timestamps via `Repo.update_all`; and any query with user-visible
  ordering must carry a tiebreaker (`desc: id`) so colliding timestamps cannot
  produce a nondeterministic order.

- **The rate limiter is stubbed by default.** All checks go through the
  `BaudrateWeb.RateLimiter` behaviour (ADR 0012); tests use
  `RateLimiter.Sandbox` with `set_global_response({:allow, 1})`. Tests that
  genuinely exercise limiting use `set_fun(&RateLimiter.Hammer.check_rate/3)`
  and must reset with `BaudrateWeb.RateLimit.reset_all/0` in setup.

- **Federation delivery is synchronous in tests** (`federation_async: false`),
  because an async `Task` does not own the Ecto sandbox connection.

- **Three test layers:** `Baudrate.DataCase` for contexts,
  `BaudrateWeb.ConnCase` for controllers and LiveViews, and Wallaby + Selenium
  feature tests (`BaudrateWeb.FeatureCase`) for genuine browser behaviour.
  Feature tests are tagged `@moduletag :feature` and excluded by default —
  they need a running Selenium and Firefox — and run with
  `mix test --include feature`.

- **Acceptance gates for invariants.** Where an invariant is a property of the
  whole system rather than of one module, it gets a dedicated test:
  `test/baudrate_web/no_hotlink_test.exs` is the gate for ADR 0006.

- `mix precommit` (compile with `--warnings-as-errors`, unused-dep unlock,
  format, test) is the pre-commit contract.

## Consequences

- A red test is a real signal, which is the entire point.
- Wallaby 0.30 predates Selenium 4's W3C protocol, so two compatibility layers
  are carried deliberately: `BaudrateWeb.W3CWebDriver` for session
  capabilities, and a runtime module override
  (`test/support/wallaby_httpclient_patch.exs`, loaded with
  `ignore_module_conflict: true`) for request bodies, `set_value` format, URL
  rewrites and W3C error shapes. This is a maintenance liability to revisit
  when Wallaby catches up.
- `config/test.exs` runs a real server on per-partition ports (4002 + partition)
  so partitions do not collide; `wax_`'s `origin` must match that port.

## Alternatives considered

- **Random seeds.** Rejected: irreproducible failures.
- **A real rate limiter everywhere.** Rejected: makes the suite
  order-dependent for no added coverage — the limiter has its own tests.
- **Single-partition serial runs.** Rejected: slower, and it hides exactly the
  concurrency bugs worth finding.
