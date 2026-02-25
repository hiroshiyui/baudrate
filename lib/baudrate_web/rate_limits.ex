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
  | `check_mute_user/1`     | `mute_user:`       | 5 min   | 10    |
  | `check_search/1`        | `search:`          | 1 min   | 15    |
  | `check_search_by_ip/1`  | `search:ip:`       | 1 min   | 10    |
  | `check_avatar_change/1` | `avatar_change:`   | 1 hour  | 5     |
  | `check_dm_send/1`       | `dm_send:`         | 1 min   | 20    |
  | `check_outbound_follow/1`| `outbound_follow:` | 1 hour  | 10    |
  """

  require Logger

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

  defp check(bucket, scale_ms, limit, action) do
    case Hammer.check_rate(bucket, scale_ms, limit) do
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
