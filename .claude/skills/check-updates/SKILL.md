---
name: check-updates
description: Check updates and security advisories across Hex packages, the esbuild/Tailwind/daisyUI toolchain and the Rust NIF crates; report by risk. Reports only; upgrades need the user's confirmation.
---

Cover all three ecosystems. **Report only**: edit nothing (`mix.exs`,
`config/config.exs`, `Cargo.toml`, vendored files) until the user picks the bumps.

## 1. Hex
```bash
mix hex.outdated   # Status: "Update possible" vs "Update not possible" (constraint pins it)
mix hex.audit      # retired / insecure: ALWAYS run, top priority
```
`mix hex.outdated <dep>` for each blocked dep. Extra care even on minors: `phoenix`,
`phoenix_live_view`, `req` (the SSRF guard and DNS pinning use its internals), `bandit`,
`ecto_sql`/`postgrex`, `bcrypt_elixir`, `wax_`, `nimble_totp`, `hammer`, `rustler`.

## 2. Frontend
```bash
grep -A1 'config :esbuild' config/config.exs
grep -A1 'config :tailwind' config/config.exs
mix tailwind baudrate 2>&1 | grep -i daisyui      # vendored daisyUI + tailwind versions
for pkg in esbuild "@tailwindcss/cli" daisyui; do
  echo "$pkg → $(curl -sS "https://registry.npmjs.org/$pkg/latest" | grep -oE '"version":"[^"]+"' | head -1)"
done
```
daisyUI is vendored (`assets/vendor/daisyui*.js`, URL in the `app.css` comment). Any
Tailwind/daisyUI bump needs a visual check of the themes.

## 3. Rust crates
```bash
grep -E '^(ammonia|scraper|feedparser-rs|rustler)\b' native/*/Cargo.toml
for c in ammonia scraper feedparser-rs rustler; do
  echo "$c → $(curl -sS -H 'User-Agent: baudrate-dep-check/1.0' \
    https://crates.io/api/v1/crates/$c | grep -oE '"max_stable_version":"[^"]+"' | head -1)"
done
```
The Hex `rustler` and every crate's `rustler` move together. `ammonia` and
`scraper`/`html5ever` are on the XSS boundary: security-relevant.

## Report (by risk, not ecosystem)
- **Security:** `hex.audit` hits, advisory fixes, anything on the SSRF / sanitizer /
  auth / crypto boundary.
- **Framework:** major/minor bumps of Phoenix, LiveView, Ecto, Bandit, Req, Hammer,
  Tailwind/daisyUI, or any constraint edit.
- **Routine:** everything else the constraint allows.

Each: current → latest, ecosystem, constraint edit needed, one-line risk. Name the
clean ecosystems.

## Applying (after the user chooses)
Smallest safe set first, framework majors separate. Hex: `mix deps.update <dep>` (or
edit the constraint). Rust: bump `Cargo.toml` with `rustler` in lockstep, then
`mix deps.compile <nif> --force`. Frontend: edit `config/config.exs` or re-vendor, then
`mix assets.build`. Full suite (seed 9527, 4 partitions) after every batch; stop on
failure. Commit by ecosystem.
