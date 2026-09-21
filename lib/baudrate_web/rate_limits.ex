defmodule BaudrateWeb.RateLimits do
  @moduledoc """
  Centralized per-user rate limit checks for authenticated endpoints.

  Each function takes a `user_id` (integer) and returns `:ok` or
  `{:error, :rate_limited}`. On backend errors, **fails open** (returns `:ok`)
  to avoid denying service due to infrastructure issues — consistent with the
  IP-based `RateLimit` plug.

  Admin users are trusted and should be exempted by callers; this module does
  not check roles.

  ## Limits

  | Function                | Bucket prefix      | Window  | Limit |
  |-------------------------|--------------------|---------|-------|
  | `check_create_article/1`| `article_create:`  | 15 min  | 10    |
  | `check_update_article/1`| `article_update:`  | 5 min   | 20    |
  | `check_create_comment/1`| `comment_create:`  | 5 min   | 30    |
  | `check_update_comment/1`| `comment_update:`  | 5 min   | 20    |
  | `check_delete_content/1`| `delete_content:`  | 5 min   | 20    |
  | `check_moderator_delete/1`| `moderator_delete:` | 5 min | 100   |
  | `check_mute_user/1`     | `mute_user:`       | 5 min   | 10    |
  | `check_search/1`        | `search:`          | 1 min   | 15    |
  | `check_draft_save/1`    | `draft_save:`      | 1 min   | 60    |
  | `check_search_by_ip/1`  | `search:ip:`       | 1 min   | 10    |
  | `check_avatar_change/1` | `avatar_change:`   | 1 hour  | 5     |
  | `check_dm_send/1`       | `dm_send:`         | 1 min   | 20    |
  | `check_outbound_follow/1`| `outbound_follow:` | 1 hour  | 10    |
  | `check_create_report/1` | `report_create:`   | 15 min  | 5     |
  | `check_mention_resolve/1` | `mention_resolve:` | 1 hour | 30   |
  | `check_timeline_reply/1`   | `timeline_reply:`      | 5 min   | 20    |
  | `check_link_preview_domain/1` | `lp_domain:` | 1 min   | 10    |
  | `check_link_preview_user/1`   | `lp_user:`   | 1 min   | 5     |
  | `check_reply_chain_fetch/1`   | `reply_chain:` | 1 min | 10    |
  | `check_reply_chain_domain/1`  | `reply_chain_domain:` | 1 min | 20 |
  | `check_media_fetch_domain/1`  | `media_domain:` | 1 min | 20   |
  | `check_media_fetch_ip/1`      | `media_fetch_ip:` | 1 min | 20 |
  | `check_media_fetch_global/0`  | `media_fetch:global` | 1 min | 600 |
  | `check_admin_sudo/1`          | `admin_sudo:`      | 15 min  | 5     |
  | `check_reauth/1`              | `reauth:`          | 15 min  | 5     |
  | `check_inbound_flag/1`        | `inbound_flag:`    | 1 hour  | 10    |
  | `check_account_reset_by_ip/1` | `account_reset:ip:` | 1 hour | 10   |
  | `check_recovery_codes/1`      | `recovery_codes:`  | 1 hour  | 5     |
  | `check_remote_follow_domain/1` | `remote_follow_domain:` | 1 min | 10 |
  """

  require Logger

  @doc """
  Admin sudo re-verification (TOTP or WebAuthn): 5 attempts per 15 minutes
  per user.

  Keyed on the user id, not the session or IP, so the lockout cannot be reset
  by discarding the cookie's attempt counter or spread across many source
  addresses. Every attempt counts, successful or not — a legitimate admin
  never needs more than a couple of sudo prompts in a quarter hour, while a
  6-digit TOTP brute force needs thousands.
  """
  @spec check_admin_sudo(integer()) :: :ok | {:error, :rate_limited}
  def check_admin_sudo(user_id) do
    check("admin_sudo:#{user_id}", 900_000, 5, :admin_sudo)
  end

  @doc """
  Step-up re-authentication (password, plus TOTP when enabled) from an
  authenticated session: 5 attempts per 15 minutes per user.

  Shared by every re-authentication form (security key management, TOTP
  reset), so a stolen session cannot multiply its password guesses by
  switching forms. Every attempt counts, successful or not. This bucket fails
  open like all Hammer checks; the fail-closed backstop is the database-backed
  per-account login throttle that `Baudrate.Auth.verify_reauthentication/5`
  enforces.
  """
  @spec check_reauth(integer()) :: :ok | {:error, :rate_limited}
  def check_reauth(user_id) do
    check("reauth:#{user_id}", 900_000, 5, :reauth)
  end

  @doc """
  Issuing a fresh set of recovery codes: 5 per hour per user.

  Step-up re-authentication is itself limited, but it opens a five-minute
  window in which the handler behind it is free. Each regeneration writes ten
  rows and sends an always-delivered notice, which can be one Web Push per
  subscribed device — nobody needs five sets of codes in an hour, and a
  scripted loop should not be able to turn a member's own session into
  outbound push traffic.
  """
  @spec check_recovery_codes(integer()) :: :ok | {:error, :rate_limited}
  def check_recovery_codes(user_id) do
    check("recovery_codes:#{user_id}", 3_600_000, 5, :recovery_codes)
  end

  @doc """
  Redeeming an admin-issued account reset link: 10 attempts per hour per IP.

  The token is 32 random bytes, so there is nothing here to brute force. This
  bounds the *password* attempts against one link instead — a redemption that
  fails on a weak password spends the link, so a loop of them is noise rather
  than an attack, and it should still be noise somebody has to work at.
  """
  @spec check_account_reset_by_ip(String.t()) :: :ok | {:error, :rate_limited}
  def check_account_reset_by_ip(ip) do
    check("account_reset:ip:#{ip}", 3_600_000, 10, :account_reset_ip)
  end

  @doc "Article creation: 10 per 15 minutes per user."
  @spec check_create_article(integer()) :: :ok | {:error, :rate_limited}
  def check_create_article(user_id) do
    check("article_create:#{user_id}", 900_000, 10, :create_article)
  end

  @doc "Article update: 20 per 5 minutes per user."
  @spec check_update_article(integer()) :: :ok | {:error, :rate_limited}
  def check_update_article(user_id) do
    check("article_update:#{user_id}", 300_000, 20, :update_article)
  end

  @doc "Comment creation: 30 per 5 minutes per user."
  @spec check_create_comment(integer()) :: :ok | {:error, :rate_limited}
  def check_create_comment(user_id) do
    check("comment_create:#{user_id}", 300_000, 30, :create_comment)
  end

  @doc """
  Comment edit: 20 per 5 minutes per user.

  The same allowance as an article edit, and for the same reason: an edit is
  cheap for the member and not cheap for us — it re-renders markdown through
  two NIFs and enqueues an `Update` to every follower of the thread — so the
  bound is on the fan-out, not on how often somebody may change their mind.
  """
  @spec check_update_comment(integer()) :: :ok | {:error, :rate_limited}
  def check_update_comment(user_id) do
    check("comment_update:#{user_id}", 300_000, 20, :update_comment)
  end

  @doc "Content deletion (articles or comments): 20 per 5 minutes per user."
  @spec check_delete_content(integer()) :: :ok | {:error, :rate_limited}
  def check_delete_content(user_id) do
    check("delete_content:#{user_id}", 300_000, 20, :delete_content)
  end

  @doc """
  Content deletion by a moderator: 100 per 5 minutes per user (1B).

  Moderators clearing a spam wave hit the author limit of 20, which is meant
  to slow down someone wiping their own history, not moderation; they get
  their own, higher limit instead.
  """
  @spec check_moderator_delete(integer()) :: :ok | {:error, :rate_limited}
  def check_moderator_delete(user_id) do
    check("moderator_delete:#{user_id}", 300_000, 100, :moderator_delete)
  end

  @doc "User muting: 10 per 5 minutes per user."
  @spec check_mute_user(integer()) :: :ok | {:error, :rate_limited}
  def check_mute_user(user_id) do
    check("mute_user:#{user_id}", 300_000, 10, :mute_user)
  end

  @doc "Search (authenticated): 15 per minute per user."
  @spec check_search(integer()) :: :ok | {:error, :rate_limited}
  def check_search(user_id) do
    check("search:#{user_id}", 60_000, 15, :search)
  end

  @doc """
  Installation key attempts: 10 per 15 minutes per IP address.

  `SetupLive` kept a three-strikes lockout in socket assigns, which an
  attacker resets by opening another socket — "a lockout kept in socket
  assigns or the cookie is resettable by the attacker" (ADR 0022). `/setup`
  also sits outside every `live_session`, so `:rate_limit_mount` never bounded
  the sockets either.
  """
  @spec check_installation_key(String.t()) :: :ok | {:error, :rate_limited}
  def check_installation_key(ip) do
    check("installation_key:#{ip}", 900_000, 10, :installation_key)
  end

  @doc """
  Autocomplete suggest: 60 per minute per user.

  These fire on keystrokes, so the ceiling is higher than `check_search/1`'s —
  but not absent, which is what it was. The hooks are attached to every
  authenticated LiveView, and `mention_suggest` is an ILIKE over `users`, so
  one socket could walk the whole member roster with prefixes `a`, `b`, …
  while completely bypassing the search limit.
  """
  @spec check_suggest(integer()) :: :ok | {:error, :rate_limited}
  def check_suggest(user_id) do
    check("suggest:#{user_id}", 60_000, 60, :suggest)
  end

  @doc "Markdown preview: 60 per minute per user."
  @spec check_preview(integer()) :: :ok | {:error, :rate_limited}
  def check_preview(user_id) do
    check("preview:#{user_id}", 60_000, 60, :preview)
  end

  @doc """
  Saving an article draft: 60 per minute per user.

  The composer debounces its autosave server-side, so ordinary typing produces
  roughly one save every two seconds and never approaches this. It is here for
  the case the debounce is defeated — a stuck client, or a reconnect loop
  re-sending `validate` — because each save is a write, and a member holding
  the composer open should not be able to turn a keyboard into a write loop.
  Modelled on `check_preview/1`, which bounds the other thing a keystroke can
  make the server do.
  """
  @spec check_draft_save(integer()) :: :ok | {:error, :rate_limited}
  def check_draft_save(user_id) do
    check("draft_save:#{user_id}", 60_000, 60, :draft_save)
  end

  @doc "Search (guest): 10 per minute per IP address."
  @spec check_search_by_ip(String.t()) :: :ok | {:error, :rate_limited}
  def check_search_by_ip(ip) do
    check("search:ip:#{ip}", 60_000, 10, :search_ip)
  end

  @doc "Avatar change: 5 per hour per user."
  @spec check_avatar_change(integer()) :: :ok | {:error, :rate_limited}
  def check_avatar_change(user_id) do
    check("avatar_change:#{user_id}", 3_600_000, 5, :avatar_change)
  end

  @doc "Direct message sending: 20 per minute per user."
  @spec check_dm_send(integer()) :: :ok | {:error, :rate_limited}
  def check_dm_send(user_id) do
    check("dm_send:#{user_id}", 60_000, 20, :dm_send)
  end

  @doc "Outbound follow: 10 per hour per user."
  @spec check_outbound_follow(integer()) :: :ok | {:error, :rate_limited}
  def check_outbound_follow(user_id) do
    check("outbound_follow:#{user_id}", 3_600_000, 10, :outbound_follow)
  end

  @doc """
  Account alias changes (ADR 0025): 10 per hour per user. Adding an alias
  makes outbound WebFinger and actor fetches, so this also bounds the requests
  one account can make other servers receive.
  """
  @spec check_account_alias(integer()) :: :ok | {:error, :rate_limited}
  def check_account_alias(user_id) do
    check("account_alias:#{user_id}", 3_600_000, 10, :account_alias)
  end

  @doc """
  Resolving an unknown `@user@domain` mention: 30 per hour per user
  (ADR 0051).

  Each unknown handle costs the named server a WebFinger request and an actor
  fetch, and the handles come from text the author chose — so without a bound
  a member could make this instance hammer someone else's, or scan a domain
  for which accounts exist. `Federation.Mentions` also caps the lookups any
  single post can trigger, so this limits the sustained rate and that limits
  the burst.

  Deliberately higher than `check_outbound_follow/1` (10/hour): mentioning
  people is ordinary writing, and the first post of a conversation can
  legitimately name several accounts nobody here has seen.
  """
  @spec check_mention_resolve(integer()) :: :ok | {:error, :rate_limited}
  def check_mention_resolve(user_id) do
    check("mention_resolve:#{user_id}", 3_600_000, 30, :mention_resolve)
  end

  @doc "Report creation: 5 per 15 minutes per user."
  @spec check_create_report(integer()) :: :ok | {:error, :rate_limited}
  def check_create_report(user_id) do
    check("report_create:#{user_id}", 900_000, 5, :create_report)
  end

  @doc """
  Issuing or lifting a sanction: 20 per 5 minutes per moderator.

  A stolen moderator session should not be able to suspend a hundred accounts
  in a minute (ADR 0029). A moderator working through a spam wave issues a
  handful; twenty in five minutes is well clear of real work and well short of
  a scripted sweep.
  """
  @spec check_sanction(integer()) :: :ok | {:error, :rate_limited}
  def check_sanction(user_id) do
    check("sanction:#{user_id}", 300_000, 20, :sanction)
  end

  @doc "Timeline item reply: 20 per 5 minutes per user."
  @spec check_timeline_reply(integer()) :: :ok | {:error, :rate_limited}
  def check_timeline_reply(user_id) do
    check("timeline_reply:#{user_id}", 300_000, 20, :timeline_reply)
  end

  @doc "Link preview domain fetch: 10 per minute per domain."
  @spec check_link_preview_domain(String.t()) :: :ok | {:error, :rate_limited}
  def check_link_preview_domain(domain) do
    check("lp_domain:#{domain}", 60_000, 10, :link_preview_domain)
  end

  @doc "Link preview user fetch: 5 per minute per user."
  @spec check_link_preview_user(integer()) :: :ok | {:error, :rate_limited}
  def check_link_preview_user(user_id) do
    check("lp_user:#{user_id}", 60_000, 5, :link_preview_user)
  end

  @doc """
  Reply-chain fetch against a remote host: 10 per minute per **target** host.

  Keyed on the host being fetched, not the sender, so a swarm of hostile
  domains all pointing their `inReplyTo` at one victim still cannot exceed
  10 requests/minute against it.
  """
  @spec check_reply_chain_fetch(String.t()) :: :ok | {:error, :rate_limited}
  def check_reply_chain_fetch(host) do
    check("reply_chain:#{host}", 60_000, 10, :reply_chain_fetch)
  end

  @doc """
  Remote-follow lookup against a domain: 10 per minute per **target** domain.

  A visitor types a handle and this instance fetches that domain's WebFinger
  document, so the limit is keyed on the domain being asked, not on who asked
  — exactly `check_reply_chain_fetch/1`'s reasoning. Keyed on the visitor
  alone, many visitors (or one behind many addresses) could combine into a
  respectable amount of traffic aimed at a single server that never asked to
  hear from us.

  Ten a minute is the same number as the reply-chain walk, and for the same
  reason: a real instance is looked up once per visitor who wants to follow
  someone, which for any one domain is a rare event. Anything approaching the
  limit is not people following each other.

  The per-IP half is `BaudrateWeb.Plugs.RateLimit`'s `:remote_follow` bucket;
  both apply, and it is the one that stops a single visitor looping.
  """
  @spec check_remote_follow_domain(String.t()) :: :ok | {:error, :rate_limited}
  def check_remote_follow_domain(domain) do
    check("remote_follow_domain:#{domain}", 60_000, 10, :remote_follow_domain)
  end

  @doc """
  Media proxy fetch against a remote host: 20 per minute per host.

  Only checked on a cache **miss** — cache hits are bounded by the per-IP plug
  limit instead. Keeps this instance from being used to hammer a third party.
  """
  @spec check_media_fetch_domain(String.t() | nil) :: :ok | {:error, :rate_limited}
  def check_media_fetch_domain(nil), do: {:error, :rate_limited}

  def check_media_fetch_domain(host) do
    check("media_domain:#{host}", 60_000, 20, :media_fetch_domain)
  end

  @doc "Media proxy fetch triggered by one client: 20 per minute per IP."
  @spec check_media_fetch_ip(String.t()) :: :ok | {:error, :rate_limited}
  def check_media_fetch_ip(ip) do
    check("media_fetch_ip:#{ip}", 60_000, 20, :media_fetch_ip)
  end

  @doc "Instance-wide media proxy egress ceiling: 600 fetches per minute."
  @spec check_media_fetch_global() :: :ok | {:error, :rate_limited}
  def check_media_fetch_global do
    check("media_fetch:global", 60_000, 600, :media_fetch_global)
  end

  @doc "Reports (inbound `Flag`) accepted from one remote domain: 10 per hour."
  @spec check_inbound_flag(String.t()) :: :ok | {:error, :rate_limited}
  def check_inbound_flag(domain) do
    check("inbound_flag:#{domain}", 3_600_000, 10, :inbound_flag)
  end

  @doc "Reply-chain walks initiated by a remote domain: 20 per minute."
  @spec check_reply_chain_domain(String.t()) :: :ok | {:error, :rate_limited}
  def check_reply_chain_domain(domain) do
    check("reply_chain_domain:#{domain}", 60_000, 20, :reply_chain_domain)
  end

  defp check(bucket, scale_ms, limit, action) do
    case BaudrateWeb.RateLimiter.check_rate(bucket, scale_ms, limit) do
      {:allow, _count} ->
        :ok

      {:deny, _limit} ->
        Logger.warning("rate_limit.denied: action=#{action} bucket=#{bucket}")
        {:error, :rate_limited}

      {:error, reason} ->
        Logger.error(
          "rate_limit.error: action=#{action} bucket=#{bucket} reason=#{inspect(reason)}"
        )

        # Fail open to avoid blocking legitimate users on backend errors
        :ok
    end
  end
end
