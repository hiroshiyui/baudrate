---
name: check-updates
description: Check for available updates and security advisories across every dependency ecosystem Baudrate uses — Elixir/Hex packages, the esbuild/Tailwind/daisyUI frontend toolchain, and the Rust NIF crates — then report what is outdated, what is blocked by a version constraint, and what is retired/insecure, grouped by risk. Reports findings; does not upgrade without confirmation.
---

Baudrate spans three dependency ecosystems (Elixir/Hex, vendored/CLI frontend
tooling, Rust NIF crates), so a complete update check must cover all three — a
`mix hex.outdated` alone misses the JS toolchain and the `native/` crates.

This skill **reports**. Do not edit `mix.exs`, `config/config.exs`, `Cargo.toml`,
or vendored files, and do not run any upgrade, without explicit user confirmation
of the specific bumps to apply (a framework major/minor bump can break the build).

---

## Step 1 — Elixir / Hex dependencies

```bash
mix hex.outdated        # every dep: Current vs Latest, and whether the mix.exs constraint allows it
mix hex.audit           # retired / deprecated / insecure packages (ALWAYS run — security-relevant)
```

- Note each dep's **Status** column: `Update possible` (constraint already allows it) vs `Update not possible` (the `~>` requirement in `mix.exs` pins it — an upgrade needs a constraint edit and is usually a minor/major framework bump).
- For every `Update not possible`, run `mix hex.outdated <dep>` to see the exact `mix.exs` requirement and what is blocking it.
- Treat **`mix hex.audit` output as the top priority** — a retired/insecure package is a security finding, not a routine bump. (Known example: `earmark` is retired/deprecated — upstream recommends MDEx.)
- Flag the **security- and framework-critical** deps for extra care even on a minor bump: `phoenix`, `phoenix_live_view`, `req` (HTTP client — the SSRF guard and DNS pinning depend on Req internals), `bandit`, `ecto_sql`/`postgrex`, `bcrypt_elixir`, `wax_`, `nimble_totp`, `hammer`, `rustler` (must stay in lockstep with the Rust-side crate — see Step 3).

## Step 2 — Frontend toolchain

The JS/CSS tools are not in `mix hex.outdated`. Two are version-pinned in
`config/config.exs`; daisyUI is vendored under `assets/vendor/`.

```bash
# Pinned installer versions
grep -A1 'config :esbuild' config/config.exs   # version: "..."
grep -A1 'config :tailwind' config/config.exs  # version: "..."

# Vendored daisyUI version — read it from a build's banner
mix tailwind baudrate 2>&1 | grep -i daisyui   # prints "daisyUI x.y.z"; the same line shows "tailwindcss vX.Y.Z"

# Latest published versions
for pkg in esbuild "@tailwindcss/cli" daisyui; do
  echo "$pkg → $(curl -sS "https://registry.npmjs.org/$pkg/latest" | grep -oE '"version":"[^"]+"' | head -1)"
done
```

- Compare pinned/vendored versions against the npm `latest`.
- daisyUI is vendored (`assets/vendor/daisyui.js` + `daisyui-theme.js`), so updating it means re-fetching those files per the URL in the `app.css` comment — note that, don't attempt it silently.
- A Tailwind/daisyUI bump can shift component styles — call out that any bump needs a visual check of the themes (including the custom `light`/`dark`/`aquaosx` themes).

## Step 3 — Rust NIF crates

Each `native/*/Cargo.toml` pins crate versions. `cargo-outdated` is usually not
installed, so query crates.io directly (it **requires** a `User-Agent` header).

```bash
grep -E '^(ammonia|scraper|feedparser-rs|rustler)\b' native/*/Cargo.toml

for c in ammonia scraper feedparser-rs rustler; do
  latest=$(curl -sS -H "User-Agent: baudrate-dep-check/1.0" \
    "https://crates.io/api/v1/crates/$c" | grep -oE '"max_stable_version":"[^"]+"' | head -1)
  echo "$c → $latest"
done
```

- **`rustler` must match on both sides**: the Elixir `rustler` Hex dep (Step 1) and the `rustler = "..."` in every `native/*/Cargo.toml` need compatible versions. Bumping one without the other breaks NIF compilation. Report them together.
- `ammonia` (HTML sanitizer) and `scraper`/`html5ever` (HTML parser) are on the federation/XSS security boundary — flag their updates as security-relevant.
- Note that updating a crate requires the Rust toolchain and a NIF recompile (`mix deps.compile <nif> --force`), so it is heavier than a pure-Elixir bump.

---

## Reporting

Present a single consolidated table/list grouped by **risk**, not by ecosystem:

| Priority | Criteria |
|----------|----------|
| **Security** | Anything from `mix hex.audit`, or a bump that patches a known advisory, or an outdated crate/dep on the SSRF / sanitizer / auth / crypto boundary |
| **Framework (needs care)** | Major/minor bumps of Phoenix, LiveView, Ecto, Bandit, Req, Hammer, Tailwind/daisyUI, or any `Update not possible` requiring a `mix.exs` constraint edit — each needs its changelog read and the full test suite run |
| **Routine** | Patch/minor bumps of everything else where the constraint already allows it |

For each entry give: **current → latest**, the ecosystem, whether a constraint edit
is required, and a one-line risk note (e.g. "Req 0.5→0.6: SSRF guard depends on Req
internals — read changelog"). State explicitly which ecosystems were clean.

## Applying updates (only after the user picks what to bump)

1. Apply the smallest safe set first (routine patch/minor with `Update possible`); keep framework majors separate.
2. For Hex: `mix deps.update <dep>` (or edit the `~>` constraint for blocked ones), then `mix deps.get`.
3. For Rust: bump `native/*/Cargo.toml`, keeping `rustler` in lockstep with the Hex dep, then `mix deps.compile <nif> --force`.
4. For frontend: edit the `config/config.exs` version (esbuild/tailwind) or re-vendor daisyUI, then `mix assets.build`.
5. **Run the full suite after every batch** and stop on any failure:
   ```bash
   for p in 1 2 3 4; do MIX_TEST_PARTITION=$p mix test --partitions 4 --seed 9527 & done; wait
   ```
6. For a Tailwind/daisyUI bump, also visually verify the themes. Commit by ecosystem/topic.
