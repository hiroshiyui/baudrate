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
  alias Baudrate.Bots.{Bot, BotFeedItem}
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

  @doc "Updates a bot's configuration."
  @spec update_bot(Bot.t(), map()) :: {:ok, Bot.t()} | {:error, Ecto.Changeset.t()}
  def update_bot(bot, attrs) do
    bot
    |> Bot.update_changeset(attrs)
    |> Repo.update()
  end

  @doc "Deletes a bot and its associated user account in a transaction."
  @spec delete_bot(Bot.t()) :: {:ok, Bot.t()} | {:error, term()}
  def delete_bot(bot) do
    bot = Repo.preload(bot, :user)

    Repo.transaction(fn ->
      case Repo.delete(bot) do
        {:ok, deleted_bot} ->
          case Repo.delete(bot.user) do
            {:ok, _} -> deleted_bot
            {:error, changeset} -> Repo.rollback(changeset)
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

  @doc "Returns true if the bot has already posted the given feed item GUID."
  @spec already_posted?(Bot.t(), String.t()) :: boolean()
  def already_posted?(%Bot{id: bot_id}, guid) do
    Repo.exists?(from fi in BotFeedItem, where: fi.bot_id == ^bot_id and fi.guid == ^guid)
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
      min(5 * :math.pow(2, new_error_count - 1) |> round(), 1440)

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

  @doc "Returns true if the bot's avatar needs to be refreshed (nil or older than 7 days)."
  @spec avatar_needs_refresh?(Bot.t()) :: boolean()
  def avatar_needs_refresh?(%Bot{avatar_refreshed_at: nil}), do: true

  def avatar_needs_refresh?(%Bot{avatar_refreshed_at: refreshed_at}) do
    cutoff = DateTime.add(DateTime.utc_now(), -7 * 24 * 3600, :second)
    DateTime.compare(refreshed_at, cutoff) == :lt
  end

  @doc "Updates avatar_refreshed_at to the current time."
  @spec mark_avatar_refreshed(Bot.t()) :: {:ok, Bot.t()} | {:error, Ecto.Changeset.t()}
  def mark_avatar_refreshed(bot) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    bot
    |> Ecto.Changeset.cast(%{avatar_refreshed_at: now}, [:avatar_refreshed_at])
    |> Repo.update()
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

  defp set_display_name(user, display_name) do
    case Auth.update_display_name(user, display_name) do
      {:ok, updated} -> updated
      {:error, _} -> user
    end
  end

  defp ensure_keypair(user) do
    case KeyStore.ensure_user_keypair(user) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end
end
