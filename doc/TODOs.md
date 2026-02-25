# Baudrate — Project TODOs

Audit date: 2026-02-25

---

## Security

- [ ] **Tighten CSP** — remove `'unsafe-inline'` from `style-src` in `router.ex:64-66`. _Deferred: DaisyUI/LiveView require inline styles; removing breaks UI. Needs nonce-based CSP approach._

## Code Quality

- [ ] **Split large modules** — _deferred: high risk, needs incremental approach over multiple sessions._
- [ ] **Fix function naming inconsistency** — _deferred: analysis shows naming is mostly consistent; `get_user/1` uses tuples justifiably for multiple failure modes._

## Planned Features

_(No planned features at this time.)_
