# Contributing to Baudrate

Thank you for your interest. Baudrate is a public forum that federates over
ActivityPub, and it aims to be **a boring but friendly place for online
discussion** ([ADR 0056](doc/adr/0056-boring-but-friendly.md)). Please read
that record before proposing a feature whose purpose is to bring people back.

Found a security problem? Do not open an issue. See [SECURITY.md](SECURITY.md).

By taking part you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).

## Getting set up

You have two options.

### The dev container (recommended)

`.devcontainer/` runs the **same image CI tests in**, pinned by digest, with a
PostgreSQL 15 service beside it. You need Docker (or Podman) and an editor
that opens dev containers (VS Code, or the `devcontainer` CLI). Nothing else
has to be installed on your machine.

1. Open the repository in the container. Its first start runs `mix setup` and
   `mix phx.gen.cert`.
2. `mix phx.server`, then open https://localhost:4001 (the port is
   forwarded).

### Your own toolchain

- **Erlang and Elixir** at the versions in `.tool-versions` (asdf or mise
  read it).
- **Rust**, stable: three NIF crates in `native/` are compiled from source by
  `mix compile`. There are no precompiled binaries, on purpose (decision
  P8-D1 in `doc/TODOs.md`).
- **PostgreSQL 15** (production's version; newer servers work for
  development, but CI runs 15), with the `pg_trgm` extension available.
- **libvips** for image processing.

The database settings default to user `baudrate_db_user`, password
`baudrate_database` on `localhost:5432`. The standard `PGUSER`, `PGPASSWORD`,
`PGHOST` and `PGPORT` variables override them (`PGDATABASE` too, in
development only).

```bash
mix setup           # dependencies, databases, assets
mix phx.gen.cert    # a self-signed certificate for local HTTPS
mix phx.server      # https://localhost:4001
```

On the first visit you are sent to `/setup` to create the admin account.

## Running the tests

Always run the full suite with **seed 9527 in 4 partitions**:

```bash
for p in 1 2 3 4; do MIX_TEST_PARTITION=$p mix test --partitions 4 --seed 9527 & done; wait
```

Browser tests (Wallaby with Firefox) are excluded by default. Run them when
you change templates, CSS or anything in `assets/js/`:

```bash
rm -f priv/static/assets/{css,js}/*.gz priv/static/cache_manifest.json
mix assets.build
mix test --include feature test/baudrate_web/features/
```

`mix precommit` runs what CI checks first: compiling with warnings as
errors, formatting, Credo and the tests. CI also runs Sobelow and a
dependency audit, and every Sobelow finding fails the build.

## Where to start reading

- [`CLAUDE.md`](CLAUDE.md): the conventions and the "Key Gotchas", the
  non-obvious rules the code depends on. Its name reflects the assistant it
  was first written for, but it is the project's working rulebook.
- [`doc/development.md`](doc/development.md): the architecture and the
  project tree.
- [`doc/adr/`](doc/adr/README.md): *why* things are the way they are. Before
  "simplifying" something that looks over-built, check whether a record
  explains what it defends.
- [`doc/baudrate-spec.md`](doc/baudrate-spec.md): every invariant, the code
  that enforces it and the test that fails when it breaks.

## Making a change

- **Branch from `current`** and open your pull request against `current`.
  `main` only moves when a release is cut.
- **Commit by topic**, with [Conventional Commits](https://www.conventionalcommits.org/)
  messages (`feat(bots): …`, `fix(federation): …`) that say *why* as well as
  what.
- **Tests** go in `test/`, mirroring `lib/`. Queries with a visible order
  need a tiebreaker, and never use `Process.sleep` to separate timestamps.
- **Every user-visible string** goes through `gettext()`, with `%{var}`
  bindings, and needs a hand-written translation in `zh_TW` and `ja_JP`. Run
  `mix gettext.extract --merge` and **review every new or fuzzy entry**: the
  merge guesses translations and Gettext serves a guess as if it were
  checked. `en` entries stay blank. The `zh_TW` locale is named 台灣漢語.
- **Accessibility is a requirement, not polish.** Every meaningful element
  gets a stable semantic `id` or `class` ([ADR 0018](doc/adr/0018-semantic-ids-and-classes-for-accessibility.md)),
  every control an accessible name, and focus goes somewhere sensible when an
  action removes the focused element.
- **Documentation** is part of the change: update `doc/`, the module docs
  and, when you make a decision that is expensive to reverse, add an ADR.
- **Security rules** are listed in `CLAUDE.md`. Two of them are the ones most
  often missed: never `String.to_atom/1` on input, and never put input in a
  file path.

## Licence

Baudrate is licensed under the
[GNU Affero General Public License v3.0](https://www.gnu.org/licenses/agpl-3.0.html).
By contributing you agree that your contribution is licensed under the same
terms.
