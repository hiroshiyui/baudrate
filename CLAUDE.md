# Baudrate: ActivityPub-enabled Bulletin Board System

Public BBS / Web Forum built with Elixir/Phoenix + LiveView, federating via **ActivityPub**.
Baudrate is a **public information hub**, not a social network: public content stays
visible to all; blocking controls interaction, not visibility. The aim is **a boring but
friendly place for discussion** ([ADR 0056](doc/adr/0056-boring-but-friendly.md)): nothing
is ranked by engagement and no page rivers posts across boards (ADR 0054, 0055).
**Information security is the top priority** — this is a public-facing system.

**How to use this file.** Each rule below is the short form. Before changing code a rule
points at, read its full entry in [`doc/gotchas.md`](doc/gotchas.md) (search it for the
function or test named here) and its ADR in [`doc/adr/`](doc/adr/README.md).
Accepted ADRs are superseded, never rewritten; update the old record's Status line **and** its index row
(`test/doc/adr_index_test.exs`). [`doc/baudrate-spec.md`](doc/baudrate-spec.md) indexes
every invariant → record → enforcement → gate (`test/doc/spec_index_test.exs`).
[`doc/development.md`](doc/development.md) is the architecture manual.

## Quick Reference

```bash
# Requires: Elixir 1.20 / OTP 29 (.tool-versions), PostgreSQL 15, libvips, Rust (NIFs)
# — or .devcontainer/ (the CI image by digest + PostgreSQL 15)
# Dev/test DB: baudrate_db_user / baudrate_database; PGUSER, PGPASSWORD, PGHOST, PGPORT override
mix setup              # deps, DB, assets
mix phx.server         # https://localhost:4001
mix precommit          # compile --warnings-as-errors, unlock unused, format check, credo --strict, test
# Full suite: always seed 9527, 4 partitions
for p in 1 2 3 4; do MIX_TEST_PARTITION=$p mix test --partitions 4 --seed 9527 & done; wait
```

## Stack

Elixir 1.20 / OTP 29 (pinned in `.tool-versions`) · Phoenix 1.8 / LiveView 1.2 · Bandit ·
PostgreSQL 15 (production's major) · Tailwind + DaisyUI · esbuild · **Req only** (never
HTTPoison, Tesla, httpc) · libvips via `image` (WebP re-encode, EXIF strip) · Hammer 7 ·
MDEx · wax_ · Rust NIFs (Ammonia, scraper, feedparser-rs) · Gettext (en, zh_TW, ja_JP).
Contexts and architecture: `doc/development.md`.

## Key Gotchas

Full text of each: `doc/gotchas.md`. "Gate" names the acceptance test; a new surface of
that kind goes in it.

### Product shape
- **No ranking, no cross-board river** (ADR 0054/0055): no `/popular`, `/trending`,
  `/hot`, `/recent`, `/top`, `/unanswered`; home lists boards in `Board.position` order,
  no post counts. Search, tags, feeds, the personal timeline and in-board chronology are
  exempt. Gate: `no_content_ranking_test.exs`.
- **Soft delete** (`deleted_at`) is deferred: `Retention` hard-deletes after 90 days,
  sparing anything a report references (ADR 0040).

### LiveView and templates
- Layout gets `@inner_content` (not `@inner_block`); never wrap templates in
  `<Layouts.app>` (duplicate flash ids); session writes use `phx-trigger-action` POSTs.
- Every authenticated LiveView ends `handle_info/2` with a catch-all: the unread-count
  hooks forward DM/notification PubSub messages to every page.
- Forms: `phx-change` re-renders reset inputs to the rendered `value`. Assign params back
  (`to_form(params, as: …)`) and render `value={@form[:field].value}`; `phx-change` works
  only on a form/input, never a `<fieldset>`/`<div>`; never give a form a dynamic `id`.
- Focus: `push_event(socket, "focus", %{id: …})` when an action removes the focused
  control; announce PubSub arrivals with an `sr-only role="status"` node, never
  `aria-live` on a list. `data-focus-target` on list pages (inert beside `autofocus`,
  except on `?page` changes). Paginated pages render `<.pagination>`; never push
  `scroll-to-top` (`pagination_consistency_test.exs`).
- CSS: arbitrary grid tracks use `minmax(0,1fr)` + `min-w-0` + `break-words` on
  user/remote text. Make the *container* flex, never an `inline-flex` link or a `<td>`
  (baseline shift; put a `<div class="flex">` inside the cell).
- Patched-in-place lists are keyed (`:key={item.id}`); streams only for unbounded lists.
- A comment link names its page: build with `Helpers.comment_link/3` / `comment_path/3`.
- Link authors with `<.author_link>` / `Helpers.author_path/1`, never
  `~p"/users/#{name}"` (tombstones link nowhere).
- A hook's `pushEvent` that can fire on any page is handled in a shared `AuthHooks`
  `attach_hook`, never per LiveView.

### Federation — trust and origin (ADR 0046)
- An identity claim is honoured only from the host that can prove it:
  `Validator.same_host?/2` is the one primitive. `ActorResolver` rejects an actor `id` on
  another host; activity `id` host = actor host; `Create`/`Update` objects must live on
  the signer's host (`validate_object_origin/2`); `ObjectResolver` applies the same.
- Announce: `attributedTo` host must equal the object `id` host; never re-home local URIs
  or content the booster does not own. `Accept`/`Reject(Follow)` match the signer.
- Inbound `Move` needs the target's `alsoKnownAs` and the signer as `object`; followers
  send `Undo(Follow)` + a pending `Follow`; timeline items move with the follow; one Move
  per origin per 30 days (ADR 0025).
- Every `baudrate:` term is declared in `Federation.Context` (`protocol_hygiene_test.exs`).
- Group `Announce` of an activity (Lemmy) is a carrier: carried `Create` goes to the
  announce path; other carried types only if on the group's host (ADR 0053,
  `group_announce_test.exs`).
- Remote strings reaching a column need a bound (truncate at ingest + `validate_length`);
  `TitleDeriver.truncate_title/2` counts the ellipsis. Remote `url` is https-only; peer
  `published_at` clamped to now. Remote names/usernames go through `Federation.Sanitizer`.
- Inbound actor keys: RSA ≥ 2048 (`HTTPSignature.validate_public_key_pem/1`) at ingest and
  at verify. `sign/5`/`sign_get/3` never return a `host` header.

### Federation — gates and delivery
- **Inbound gate** (ADR 0004): only boards with `min_role_to_view == "guest"` and
  `ap_enabled` federate; `InboxHandler.article_federated?/1` gates every Like, Announce,
  reply and poll vote on a local article (exceptions: remote articles; authors with
  remote followers). Refusals drop with `:ok`.
- **Outbound gate** is `Board.federated?/1` everywhere (ADR 0043), never `public?/1`;
  withdrawals (`Delete`, `Undo`) pass `intent: :withdraw` and are never gated. Gate:
  `publisher_test.exs`.
- **Publishing commits with the change** (ADR 0034): publish inside the Multi or
  `Federation.federate/2`, never a `Task`; `schedule_federation_task/1` is best-effort
  work only. Gate: `durable_delivery_test.exs`. Inbox stores, answers 202, then
  `InboundWorker` processes (handlers idempotent; `activity_json` cleared after).
- `DeliveryCircuits`: 5 unreachable results open a domain; our own failures are
  `:neutral`. Delivery jobs dedup on `(inbox_url, actor_uri, activity_id)`.
- Call `KeyStore.ensure_user_keypair/1` before signed activities
  (`Delivery.get_private_key/1` self-heals); never for a deleted account.
- Objects we mint live at paths, never fragments (ADR 0050); `get_comment_by_ap_id/1` /
  `get_poll_by_ap_id/1` also match `legacy_ap_id`. Gate: `object_identity_test.exs`.
  Reply-chain walk: ≤5 hops, ≤3 hosts, visited set, two rate limits.
- Mentions (ADR 0051): `warm/2` before the transaction, `known/1` after; the board gate
  applies to tag, `cc`, delivery and lookup; callers preload `:boards`. Gate:
  `mentions_test.exs`. A comment's `inReplyTo` is `ObjectBuilder.reply_target_uri/2`.
- Actor updates: `Federation.update_actor/3` publishes only when the rendered document
  changed; compare documents, never field lists.
- Content warnings are `summary`/`sensitive` fields, never a body prefix (ADR 0052,
  `content_warning_test.exs`); video/audio are links, never players.
- The federated `updated` means a revision exists (`article_edited?/1`), never a
  timestamp comparison.
- NodeInfo counts people (no bots/banned) and local content; activity from
  `users.last_active_on` (a date). 2.0 carries no `software.repository`.
- Actor documents cached 180 s `public` only while `ap_authorized_fetch` is off.
- WebFinger: site actor `acct:site@host`; board subject is the bare slug.
- A closed poll announces once (`polls.final_update_sent_at`, conditional `UPDATE`).
- Remote follow (visitor's instance): template from their WebFinger, HTTPS, on the typed
  host, `refuse_blocked: true`; render a link, never redirect off-site
  (`remote_follow_test.exs`).
- Only `Federation.HTTPClient` fetches: SSRF-safe, DNS-pinned, bodies capped while
  streaming; non-AP POSTs use `post_raw/3`. `HTTPClient.private_ip?/1` is the single
  deny-list (every IPv4-in-IPv6 form decoded; Teredo refused).

### Visibility and domain blocks
- Non-public remote rows (`followers_only`/`direct`) stay off public surfaces: every
  listing applies `Filters.exclude_unservable_remote/1` (or the inline equivalent), with
  no role branch. Row gates: `ArticleHelpers.user_can_view_article?/2`,
  `ActivityPubController.publicly_servable?/1`. Gate: `remote_visibility_test.exs`.
- The personal timeline keeps `followers_only` for `Create` only; for `Announce` the
  author's audience decides; `direct` never. Every timeline filter tests booster **and**
  author, and the hand-written count SQL mirrors the query.
- Domain blocks hide at query time and delete nothing (ADR 0030,
  `blocked_domain_hiding_test.exs`); a suspended remote actor is the same predicate.
  Blocks are `domain_blocks` rows written only through `Federation.DomainBlocks`;
  resolvers refuse blocked domains and callers pass `refuse_blocked: true`.
  `remote_actors.domain` is stored downcased.
- `timeline_items` are global; every client-supplied id goes through
  `Federation.timeline_item_accessible?/2` (source actor = booster for `Announce`).
- User-page and timeline listings are viewer-gated (`viewer:` option).
- Local posts are `public`/`unlisted` only; DMs are the private channel.

### Accounts, auth and sanctions
- `Auth.ensure_can_interact/1` (ADR 0029) is called at **every** context function that
  creates content or an interaction; sanctions are `sanctions` rows decided by the clock,
  never a status or a sweep. Undo, self-delete, reporting and account security stay open.
  Terms acceptance is its last check (ADR 0031, bots exempt; `terms_gate_test.exs`).
- Blocks refuse interaction both ways, locally only; no `Block` activity (ADR 0026).
- Factor changes need `Auth.verify_reauthentication/5` (ADR 0022) and send an
  always-delivered security notice from the context. TOTP only via
  `Auth.verify_totp_code/3` (single-use, ADR 0024).
- WebAuthn: store the full `Wax.Challenge`; `pop/3` requires the purpose; `wax_` origin
  must equal `window.location.origin` exactly.
- Session deletion only through `Auth.Sessions` (broadcasts `disconnect`); keep "this"
  session by row id, never token.
- The permission catalogue is fixed at compile time; four permissions enforce anything
  (ADR 0042, `permissions_are_enforced_test.exs`).
- Bots cannot log in; managed only by `Baudrate.Bots`.
- User-facing changesets are allow-lists (ADR 0049): never cast `ap_id`, `url`,
  `published_at`, `legacy_ap_id` from params.
- Registration: proof of work (ADR 0063; worker at the bare `/challenge_worker.js`,
  re-issued after every attempt); IP/CIDR bans via `Auth.IpBans` only, checked again in
  `SessionController.establish_session/3`.
- New accounts: `Auth.check_post/4` beside `ensure_can_interact/1` at every posting
  path, decided from clock and count (ADR 0064, `trust_test.exs`).
- Recovery (ADR 0058/0067): no email; verified OpenPGP contact required; changing it
  drops to `pending`; never reset an account at/above the issuer's role.
- Account deletion is a tombstone, never `Repo.delete` of a user (ADR 0072,
  `account_deletion_test.exs` — a new personal column is cleared there or kept-listed).
- Privacy settings (ADR 0073): domain mutes are a predicate; muted words collapse, never
  remove; a follow request is no follower — every reader of `followers` filters
  `not is_nil(accepted_at)`. Gate: `privacy_settings_test.exs`.

### Content, moderation and messaging
- Held posts are `held_posts` rows; LiveViews call `Content.submit_article/3` /
  `submit_comment/2`, never `create_*` (`submit_path_test.exs`). Filters are word,
  substring or domain, never regex, applied at create, edit and every inbound route;
  DMs are never screened (ADR 0065/0066).
- Cross-posted articles need rights on every board; never remove an article from its
  last board unless that board federates (`may_leave_board?/2`). Moving needs both
  boards (ADR 0075).
- Reports of timeline items, DMs and remote actors go through `Moderation.report_*`,
  which check the reporter can see the target. Site rules are retired, never deleted
  (ADR 0032).
- Forwarding checks the source board's view gate and refuses soft-deleted sources, in
  the context (clients supply the id).
- A locked or soft-deleted article refuses inbound replies.
- Only the author edits a comment; edits keep a revision (ADR 0060). Image descriptions
  save against the upload row, never as form fields (ADR 0061).
- Poll votes are anonymous (ADR 0048, `poll_anonymity_test.exs`); inbound votes go
  through `handle_poll_vote_for_article/3`.
- DM authorization is enforced in `Messaging.create_message/3`. DMs make no
  notification row, push with an empty body, and their images are private files served
  only by `/messages/images/:id`, never federated (ADR 0071, `dm_privacy_test.exs`).
  Message search is `Messaging.Search`, never `Content.Search`.
- Watches are the member's toggles only; every path placing an article in a board calls
  `Articles.announce_arrival/2` (ADR 0070, `watch_test.exs`).
- Drafts live in localStorage **and** `article_drafts`; the orphan-image sweep spares
  draft images (ADR 0062, `draft_test.exs`).
- Bots: a feed entry is judged once and recorded (`bot_syndication_items`, never purged).

### Media, crawlers, search
- **No third-party subresources** (ADR 0006/0045): remote images through
  `Media.Proxy.url/1` or `Media.Rewriter`; stored content through `BaudrateWeb.SafeHTML`,
  never a bare `raw/1` (`no_hotlink_test.exs`, `rendered_html_passes_test.exs`). The one
  embed is click-to-load YouTube (`frame-src` exactly `youtube-nocookie.com`).
- Media proxy signs with a deterministic HMAC over the URL, never `Phoenix.Token`.
- Service worker: registered on every page at the bare literal `/service_worker.js`
  (never `~p`); caches `/offline` and `/assets/` only, never content (ADR 0059).
- Crawlers (ADR 0057): the sitemap invites only what a guest sees (no unlisted, no
  profiles, no remote); `noindex` ≠ `Disallow`; missing subjects answer 404, never a
  redirect. Gate: `crawler_surface_test.exs`.
- Search needs a scope (`SearchQuery.scoped?/1`); order by relevance or time only, with
  an `id` tiebreaker and no `distinct`; `/ap/search` pins `:newest`; the Users tab caps
  at 5 pages.
- Pagination: `Baudrate.Pagination`; pages capped at `Pagination.max_page/0` (also
  `Helpers.parse_page/1`). AP collections page by row id; build Article lists with
  `ObjectBuilder.article_objects/1` (`collections_query_count_test.exs`).
- `Repo.sanitize_like/1` for ILIKE input. Avatar sizes are integers `[120, 48, 36, 24]`.

### Operations and infrastructure
- **One node** (ADR 0033): no clustering, no shared rate-limit store; security state
  lives in the database, never ETS.
- Health report only on the loopback listener (ADR 0035); alerts after two failing polls,
  repeated daily (ADR 0044, `alerts_test.exs`). Workers beat after a completed run.
  `LOG_FORMAT=json` must never raise.
- Rate limiting: Hammer 7 through the `BaudrateWeb.RateLimiter` behaviour; never call
  `Hammer.*` directly (ADR 0012, fails open).
- Caches: settings (`SettingsCache`), boards (`BoardCache`) and domain blocks refresh via
  their context writes; a direct DB write must refresh manually.
- Secrets at rest: `Crypto.Keyring` (`:auth`, `:signing`) through `TotpVault`,
  `KeyVault`, `VapidVault` only; a new secret column goes in `Crypto.Rekey` and the export
  canary; never remove a key `Rekey.usage/0` still counts; `"legacy"` is reserved
  (ADR 0038).
- Backups never delete before a new one succeeds; never re-hash a hard-linked file
  (ADR 0028). Data export is built at download, never stored (ADR 0023; add secret
  columns to `archive_test.exs`).
- Locale: cookie → `session[:preferred_locales]` → `Accept-Language` → `en`, all through
  `BaudrateWeb.Locale.known?/1`. Time zone per request (`TimeZone.shift/1`, never
  `DateTime.shift_zone!/2`; `datetime_attr/1` is UTC).
- `Helpers.local_path/2` is the one open-redirect guard.
- `StaleActorCleaner` reads referencing FKs from `pg_constraint`, never a hand list.
- OTP releases: never `:code.priv_dir/1` in a module attribute.

## CI

- CI runs only in the project's attested images (`ci/image/`, ADR 0027/0036): pinned
  digests in `image.lock` / `build-image.lock`; no third-party actions, `curl | sh` or
  unpinned downloads; GitHub-owned actions pinned by SHA.
- **One Erlang/Elixir version everywhere**: `.tool-versions` is the pin; the Dockerfile,
  dev container and Ansible `erlang_version`/`elixir_version` must equal it
  (`verify-toolchain.sh`). The deploy installs the tag's pins and builds on the server
  (ADR 0037).
- CI tests production's PostgreSQL major, server and client; never upgrade ahead of
  production.
- The release cookie is a public placeholder; distribution is loopback-only.
- Static checks: gettext up to date, Dialyzer (fix new warnings; `.dialyzer_ignore.exs`
  holds only opaque-type and compile-flag notices, by file and kind), clippy + cargo test,
  ansible-lint. Every Sobelow finding fails CI (`# sobelow_skip` per function, never
  `--mark-skip-all`).

## Project Conventions

- Keep this file current; clarify ambiguous requirements rather than guess; follow
  ActivityPub and open standards.
- **Follow the type checker** (Elixir 1.20 and Dialyzer): delete clauses it proves
  unreachable, drop redundant guards, pin bitstring sizes; never suppress or widen. When
  it calls a correct branch unreachable, fix the spec.
- **[TOP PRIORITY a11y]** Every meaningful element carries a stable semantic `id`/`class`
  (kebab-case, page-prefixed; `:for` items get a record-derived id plus a shared class;
  only add, never remove utilities/`phx-*`/`aria-*`; CSS targets semantic selectors).
  Gate: `semantic_anchors_test.exs` (ADR 0018). WAI-ARIA, HTML5 semantics, responsive.
- **Never name a control** with `accept`, `consent`, `cookie`, `gdpr`, `ccpa`, `banner`,
  `promo`, `popup`, `overlay` or `sponsor` (content blockers hide it); notices use
  `-notice`.
- **i18n**: every user-visible string in `gettext()` with `%{var}`; zh_TW and ja_JP always
  complete; `zh_TW` is named 台灣漢語 (never 繁體中文 / 正體中文). After
  `mix gettext.extract --merge`, review every new msgid by hand: zero fuzzy entries, `en`
  msgstrs blank (`translation_coverage_test.exs`).
- **After every change**: update docs (and an ADR for expensive-to-reverse, constraining
  or security/privacy decisions); add missing tests and translations; remove finished
  TODOs; when a bug is found, sweep for the same class.
- **Branching**: all work on `current`; never commit, push or rebase `main`; `main` moves
  only by `git merge --ff-only current` at release (stop and ask if it is not a
  fast-forward).
- **Release**: CHANGELOG (Keep a Changelog) → `mix.exs` version → commit on `current`,
  push → ff-merge `main` → annotated tag → `gh release create`; read `release.yml`'s
  result. `elixir.yml` on the release commit gates the deploy.
- Tests mirror `lib/`; commit by topic; one module per file.

## Security Rules

- Never `String.to_atom/1` on user input; never user input in file paths.
- Validate at every boundary; federation HTML sanitized before storage.
- Rate limit all public endpoints; uploads checked by magic bytes, avatars re-encoded.
- Size limits: 256 KB AP payload, 64 KB content body.
- `INSTALLATION_KEY` required in production until setup completes (503 via
  `EnsureSetup`, never a boot-time raise).
- `RealIp` is fail closed; client IPs only via `RealIp.client_ip/2` or
  `Helpers.extract_peer_ip/1`; `unmap_ipv4/1` only for `::ffff:0:0/96`.
- Follow the OWASP Top 10.

## Testing

- Full suite: seed 9527, 4 partitions, run without asking. `ConnCase` for web,
  `DataCase` for contexts; helpers `setup_user/1`, `log_in_user/2`, `log_in_admin/2`,
  `errors_on/1`.
- Roles and permissions are seeded once in `test_helper.exs`; a test's own role uses a
  unique name.
- Rate limits: `RateLimiter.Sandbox.set_global_response({:allow, 1})`; real backend tests
  call `RateLimit.reset_all/0`.
- Browser tests (`--include feature`): after JS/hook changes run `js_errors_test.exs`;
  after CSS/layout changes `layout_test.exs`. Delete stale `priv/static/assets/*.gz` and
  `cache_manifest.json` first.
- Another PostgreSQL: set `PGHOST`/`PGPORT` (the Repo reads them).
- Deterministic tests: no `Process.sleep` for ordering (set timestamps with
  `Repo.update_all`); every user-visible order has an `id` tiebreaker.
