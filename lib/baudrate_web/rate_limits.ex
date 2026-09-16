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
  | `check_delete_content/1`| `delete_content:`  | 5 min   | 20    |
  | `check_moderator_delete/1`| `moderator_delete:` | 5 min | 100   |
  | `check_mute_user/1`     | `mute_user:`       | 5 min   | 10    |
  | `check_search/1`        | `search:`          | 1 min   | 15    |
  | `check_search_by_ip/1`  | `search:ip:`       | 1 min   | 10    |
  | `check_avatar_change/1` | `avatar_change:`   | 1 hour  | 5     |
  | `check_dm_send/1`       | `dm_send:`         | 1 min   | 20    |
  | `check_outbound_follow/1`| `outbound_follow:` | 1 hour  | 10    |
  | `check_create_report/1` | `report_create:`   | 15 min  | 5     |
  | `check_feed_reply/1`   | `feed_reply:`      | 5 min   | 20    |
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

  @doc "Report creation: 5 per 15 minutes per user."
  @spec check_create_report(integer()) :: :ok | {:error, :rate_limited}
  def check_create_report(user_id) do
    check("report_create:#{user_id}", 900_000, 5, :create_report)
  end

  @doc "Feed item reply: 20 per 5 minutes per user."
  @spec check_feed_reply(integer()) :: :ok | {:error, :rate_limited}
  def check_feed_reply(user_id) do
    check("feed_reply:#{user_id}", 300_000, 20, :feed_reply)
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
