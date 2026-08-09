# 0005 — Rust NIFs (Rustler) for sanitizing and parsing untrusted input

- **Status:** Accepted
- **Date:** Recorded retroactively 2026-08-09

## Context

Three hot spots parse hostile input: HTML sanitization of federated content and
user Markdown, HTML parsing for Open Graph link previews, and RSS/Atom/JSON
Feed parsing for bot accounts. All three consume bytes an attacker chooses.

The pure-Elixir options were weak in exactly the place that matters.
`html_sanitize_ex` builds on `mochiweb_html`, whose parse tree is not the HTML5
tree browsers build — a sanitizer that disagrees with the browser's parser is a
mutation-XSS generator. Elixir feed parsers likewise cover a subset of the feed
dialects in the wild.

Meanwhile Ammonia (allowlist sanitizer over html5ever), html5ever/scraper, and
feedparser-rs are widely deployed, spec-accurate, memory-safe Rust crates that
parse exactly as browsers do.

## Decision

Implement these three boundaries as Rust NIFs via **Rustler**, in
`native/`:

| Crate | NIF functions | Purpose |
|---|---|---|
| `baudrate_sanitizer` | `sanitize_federation/1`, `sanitize_markdown/1`, `strip_tags/1` | Ammonia allowlist sanitization |
| `baudrate_html_parser` | `parse_og_metadata/1`, `extract_first_url/1` | html5ever/scraper for link previews |
| `baudrate_feed_parser` | `parse_feed/1` | RSS 0.9x/2.0, RSS 1.0 (RDF), Atom 0.3/1.0, JSON Feed |

All are called through thin Elixir wrappers (e.g. `Baudrate.Sanitizer.Native`),
so the NIF boundary is a single, testable seam.

## Consequences

- Sanitization matches the browser's HTML5 tree construction, which is the
  property that makes an allowlist sanitizer sound.
- **A Rust toolchain becomes a build-time requirement** for anyone compiling
  Baudrate, and build times grow. This is stated in the README and `mix setup`
  prerequisites.
- NIFs run in the BEAM's scheduler: a pathological input that takes long enough
  would stall a scheduler. Inputs are size-capped before reaching the NIF
  (256 KB AP payload, 64 KB body), which bounds the exposure.
- A panic in Rust brings down the calling process, not the VM, but memory
  safety of the chosen crates is load-bearing — prefer well-known crates and
  keep them updated (`/check-updates` covers the Cargo manifests).

## Alternatives considered

- **`html_sanitize_ex`.** Rejected and previously replaced: non-HTML5 parse
  tree, mutation-XSS risk.
- **Shelling out to an external process per document.** Rejected: per-call
  process spawn cost on a per-render path, plus a new supervision and
  input-escaping problem.
- **Writing a spec-compliant HTML5 parser in Elixir.** Rejected: this is not
  the project's business, and getting it wrong is a security bug.
