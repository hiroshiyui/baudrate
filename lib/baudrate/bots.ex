defmodule Baudrate.Bots do
  @moduledoc """
  Context for RSS/Atom feed bot accounts.

  Bots are administrator-managed accounts that periodically fetch feeds
  and post entries as articles. Each bot is backed by a `User` account
  with `is_bot: true` and cannot be logged into by humans.
  """

  import Ecto.Query
  require Logger

  alias Baudrate.Repo
  alias Baudrate.Auth.ReservedHandle
  alias Baudrate.Bots.{Bot, BotFeedItem}
  alias Baudrate.Content.Article
  alias Baudrate.Setup.{Role, User}
  alias Baudrate.Auth
  alias Baudrate.Federation.KeyStore

  @doc "Returns all bots with their user preloaded."
  @spec list_bots() :: [Bot.t()]
  def list_bots do
    Bot
    |> order_by([b], asc: b.inserted_at)
    |> preload(:user)
    |> Repo.all()
  end

  @doc "Gets a bot by ID. Raises if not found."
  @spec get_bot!(term()) :: Bot.t()
  def get_bot!(id) do
    Bot |> preload(:user) |> Repo.get!(id)
  end

  @doc "Gets a bot by user. Returns nil if not found."
  @spec get_bot_by_user(User.t()) :: Bot.t() | nil
  def get_bot_by_user(%User{id: user_id}) do
    Repo.get_by(Bot, user_id: user_id)
  end

  @doc """
  Creates a bot user account and bot configuration in a transaction.

  `attrs` must include:
    * `:username` — bot's username
    * `:display_name` — bot's display name (optional)
    * `:feed_url` — RSS/Atom feed URL
    * `:bio` — bot bio/description (optional; defaults to the feed URL)
    * `:board_ids` — list of target board IDs
    * `:fetch_interval_minutes` — poll interval (default 60)

  The user account is created with `is_bot: true`, `dm_access: "nobody"`,
  and a random locked password (human login is rejected by `authenticate_by_password/2`).
  """
  @spec create_bot(map()) :: {:ok, Bot.t()} | {:error, :role_not_found | Ecto.Changeset.t()}
  def create_bot(attrs) do
    username = attrs["username"] || attrs[:username]
    display_name = attrs["display_name"] || attrs[:display_name]
    feed_url = attrs["feed_url"] || attrs[:feed_url]
    bio = attrs["bio"] || attrs[:bio]
    board_ids = attrs["board_ids"] || attrs[:board_ids] || []
    fetch_interval = attrs["fetch_interval_minutes"] || attrs[:fetch_interval_minutes] || 60

    user_role = Repo.one(from r in Role, where: r.name == "user")

    if is_nil(user_role) do
      {:error, :role_not_found}
    else
      Repo.transaction(fn ->
        locked_password = generate_locked_password()

        user_attrs = %{
          username: username,
          password: locked_password,
          password_confirmation: locked_password,
          role_id: user_role.id
        }

        changeset = User.bot_registration_changeset(%User{}, user_attrs)

        with {:ok, user} <- Repo.insert(changeset),
             user = if(display_name, do: set_display_name(user, display_name), else: user),
             user = set_bio(user, if(bio && bio != "", do: bio, else: feed_url)),
             :ok <- ensure_keypair(user) do
          bot_attrs = %{
            user_id: user.id,
            feed_url: feed_url,
            board_ids: board_ids,
            fetch_interval_minutes: fetch_interval,
            active: true
          }

          case Repo.insert(Bot.create_changeset(%Bot{}, bot_attrs)) do
            {:ok, bot} -> %{bot | user: user}
            {:error, changeset} -> Repo.rollback(changeset)
          end
        else
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    end
  end

  @doc """
  Updates a bot's configuration and optionally its user profile.

  In addition to the standard bot fields (`feed_url`, `board_ids`,
  `fetch_interval_minutes`, `active`), the following user-profile attrs
  are handled when present:

    * `:bio` — explicit bio text; takes precedence over the auto-bio-from-feed_url
      fallback. Pass an empty string to clear the bio.
    * `:profile_fields` — list of `%{"name" => …, "value" => …}` maps (up to 4).
      When omitted the profile fields are left unchanged.

  When `:bio` is not present and the feed URL changed, the bio is automatically
  updated to the new feed URL (legacy behaviour).
  """
  @spec update_bot(Bot.t(), map()) :: {:ok, Bot.t()} | {:error, Ecto.Changeset.t()}
  def update_bot(bot, attrs) do
    case bot |> Bot.update_changeset(attrs) |> Repo.update() do
      {:ok, _updated_bot} = ok ->
        bot = Repo.preload(bot, :user)
        update_bot_user_profile(bot, attrs)
        ok

      {:error, _} = err ->
        err
    end
  end

  @doc "Deletes a bot and its associated user account in a transaction."
  @spec delete_bot(Bot.t()) :: {:ok, Bot.t()} | {:error, term()}
  def delete_bot(bot) do
    bot = Repo.preload(bot, :user)

    Repo.transaction(fn ->
      case Repo.delete(bot) do
        {:ok, deleted_bot} ->
          case Repo.delete(bot.user) do
            {:ok, deleted_user} ->
              now = DateTime.utc_now() |> DateTime.truncate(:second)

              %ReservedHandle{}
              |> ReservedHandle.changeset(%{
                handle: deleted_user.username,
                handle_type: "user",
                reserved_at: now
              })
              |> Repo.insert!(on_conflict: :nothing)

              deleted_bot

            {:error, changeset} ->
              Repo.rollback(changeset)
          end

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc "Returns bots that are due for a fetch (active and next_fetch_at is nil or in the past)."
  @spec list_due_bots() :: [Bot.t()]
  def list_due_bots do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Bot
    |> where([b], b.active == true)
    |> where([b], is_nil(b.next_fetch_at) or b.next_fetch_at <= ^now)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Returns true if the bot has already posted a feed item matching `guid` or `url`.

  Checks both:
  - `bot_feed_items` by `(bot_id, guid)` — primary dedup key
  - `articles` by `(user_id, url)` — catches the same source article re-appearing
    with a different GUID (e.g. after a feed publisher changes their `<guid>`)
  """
  @spec already_posted?(Bot.t(), String.t(), String.t() | nil) :: boolean()
  def already_posted?(%Bot{id: bot_id, user: %{id: user_id}}, guid, url) do
    guid_seen? =
      Repo.exists?(from fi in BotFeedItem, where: fi.bot_id == ^bot_id and fi.guid == ^guid)

    url_seen? =
      is_binary(url) and url != "" and
        Repo.exists?(
          from a in Article,
            where: a.user_id == ^user_id and a.url == ^url and is_nil(a.deleted_at)
        )

    guid_seen? or url_seen?
  end

  @doc "Records that a feed item was posted (or attempted)."
  @spec record_feed_item(Bot.t(), String.t(), integer() | nil) ::
          {:ok, BotFeedItem.t()} | {:error, Ecto.Changeset.t()}
  def record_feed_item(%Bot{id: bot_id}, guid, article_id) do
    %BotFeedItem{}
    |> Ecto.Changeset.cast(%{bot_id: bot_id, guid: guid, article_id: article_id}, [
      :bot_id,
      :guid,
      :article_id
    ])
    |> Ecto.Changeset.validate_required([:bot_id, :guid])
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:bot_id, :guid])
  end

  @doc "Marks a successful fetch: resets error count and schedules the next fetch."
  @spec mark_fetch_success(Bot.t(), DateTime.t() | nil) ::
          {:ok, Bot.t()} | {:error, Ecto.Changeset.t()}
  def mark_fetch_success(bot, fetched_at \\ nil) do
    fetched_at = (fetched_at || DateTime.utc_now()) |> DateTime.truncate(:second)
    next_fetch = DateTime.add(fetched_at, bot.fetch_interval_minutes * 60, :second)

    bot
    |> Ecto.Changeset.cast(
      %{
        last_fetched_at: fetched_at,
        next_fetch_at: next_fetch,
        error_count: 0,
        last_error: nil
      },
      [:last_fetched_at, :next_fetch_at, :error_count, :last_error]
    )
    |> Repo.update()
  end

  @doc "Marks a failed fetch: increments error count and applies exponential backoff."
  @spec mark_fetch_error(Bot.t(), String.t()) :: {:ok, Bot.t()} | {:error, Ecto.Changeset.t()}
  def mark_fetch_error(bot, error_message) do
    new_error_count = bot.error_count + 1
    # Exponential backoff: 5min, 10min, 20min, 40min, 80min, ... capped at 24h
    backoff_minutes =
      min((5 * :math.pow(2, new_error_count - 1)) |> round(), 1440)

    next_fetch =
      DateTime.add(DateTime.utc_now(), backoff_minutes * 60, :second)
      |> DateTime.truncate(:second)

    bot
    |> Ecto.Changeset.cast(
      %{
        error_count: new_error_count,
        last_error: String.slice(error_message, 0, 1000),
        next_fetch_at: next_fetch
      },
      [:error_count, :last_error, :next_fetch_at]
    )
    |> Repo.update()
  end

  @doc "Resets error state and schedules an immediate re-fetch for a bot."
  @spec reset_bot_errors(Bot.t()) :: :ok
  def reset_bot_errors(bot) do
    Repo.update_all(
      from(b in Bot, where: b.id == ^bot.id),
      set: [
        error_count: 0,
        last_error: nil,
        next_fetch_at: DateTime.utc_now() |> DateTime.truncate(:second)
      ]
    )

    send(Baudrate.Bots.FeedWorker, :poll)
    :ok
  end

  @doc """
  Returns true if the bot's avatar should be automatically refreshed.

  Returns false when `favicon_fail_count` has reached 3 consecutive failures —
  auto-fetch is paused to avoid hammering unreachable sites. The admin
  "Refresh Favicon" button bypasses this check and resets the counter on
  success, re-enabling automatic fetches.
  """
  @spec avatar_needs_refresh?(Bot.t()) :: boolean()
  def avatar_needs_refresh?(%Bot{favicon_fail_count: count}) when count >= 3, do: false
  def avatar_needs_refresh?(%Bot{avatar_refreshed_at: nil}), do: true

  def avatar_needs_refresh?(%Bot{avatar_refreshed_at: refreshed_at}) do
    cutoff = DateTime.add(DateTime.utc_now(), -7 * 24 * 3600, :second)
    DateTime.compare(refreshed_at, cutoff) == :lt
  end

  @doc "Updates avatar_refreshed_at to the current time and resets favicon_fail_count to 0."
  @spec mark_avatar_refreshed(Bot.t()) :: :ok
  def mark_avatar_refreshed(bot) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.update_all(
      from(b in Bot, where: b.id == ^bot.id),
      set: [avatar_refreshed_at: now, favicon_fail_count: 0]
    )

    :ok
  end

  @doc "Increments favicon_fail_count by 1. Called after each automatic or manual fetch failure."
  @spec increment_favicon_fail_count(Bot.t()) :: :ok
  def increment_favicon_fail_count(bot) do
    Repo.update_all(
      from(b in Bot, where: b.id == ^bot.id),
      inc: [favicon_fail_count: 1]
    )

    :ok
  end

  # --- Private helpers ---

  # Generate a random locked password that satisfies the password policy:
  # lowercase, uppercase, digit, and special character requirements.
  # Uses standard base64 which includes `+` and `/` as special characters.
  # Appends "!A1" as a guaranteed prefix to ensure all character classes
  # are always present regardless of random bytes content.
  defp generate_locked_password do
    random_part = :crypto.strong_rand_bytes(45) |> Base.encode64()
    "Aa1!" <> random_part
  end

  defp update_bot_user_profile(bot, attrs) do
    new_feed_url = attrs["feed_url"] || attrs[:feed_url]
    profile_fields = attrs["profile_fields"] || attrs[:profile_fields]

    cond do
      # Explicit bio takes priority over auto-update
      Map.has_key?(attrs, "bio") or Map.has_key?(attrs, :bio) ->
        bio = attrs["bio"] || attrs[:bio] || ""
        set_bio(bot.user, bio)

      # Legacy: auto-update bio when feed_url changes and no explicit bio
      new_feed_url && new_feed_url != bot.feed_url ->
        set_bio(bot.user, new_feed_url)

      true ->
        :ok
    end

    if is_list(profile_fields) do
      set_profile_fields(bot.user, profile_fields)
    end
  end

  defp set_display_name(user, display_name) do
    case Auth.update_display_name(user, display_name) do
      {:ok, updated} -> updated
      {:error, _} -> user
    end
  end

  defp set_bio(user, bio) do
    case Auth.update_bio(user, bio) do
      {:ok, updated} -> updated
      {:error, _} -> user
    end
  end

  defp set_profile_fields(user, fields) do
    case Auth.update_profile_fields(user, fields) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end

  defp ensure_keypair(user) do
    case KeyStore.ensure_user_keypair(user) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end
end
