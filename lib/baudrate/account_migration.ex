defmodule Baudrate.AccountMigration do
  @moduledoc """
  Account migration: aliases, and moving an account to another server with
  ActivityPub `Move` (ADR 0025).

  ## Aliases

  `users.also_known_as` lists the actor ids of other accounts this user claims.
  It is published as `alsoKnownAs` on the actor document. Another server only
  accepts a `Move` of a remote account to this one if the remote account is
  listed here, and a `Move` away from here needs the destination to list this
  account in its own `alsoKnownAs`.

  Callers must have confirmed the user's identity with step-up
  re-authentication (`Baudrate.Auth.verify_reauthentication/5`, ADR 0022)
  before calling `add_alias/2` or `remove_alias/2`. Every change sends an
  always-delivered `account_alias_added` / `account_alias_removed` notice.
  """

  import Ecto.Query

  require Logger

  alias Baudrate.Federation
  alias Baudrate.Federation.RemoteActor
  alias Baudrate.Notification.Hooks
  alias Baudrate.Repo
  alias Baudrate.Setup.User

  @max_aliases 5
  @max_input_length 2048

  @doc "The maximum number of aliases an account can have."
  def max_aliases, do: @max_aliases

  @doc """
  Returns `true` while the account has moved away (`users.moved_to` is set).
  A moved account is read-only (ADR 0025).
  """
  @spec moved?(User.t() | nil) :: boolean()
  def moved?(%User{moved_to: moved_to}) when is_binary(moved_to), do: true
  def moved?(_), do: false

  @doc """
  Adds an alias to `user`.

  `input` is an `@user@domain` handle or an `https://` actor URI. It is resolved
  through `Federation.lookup_remote_actor/1` (WebFinger, then `ActorResolver`,
  which is HTTPS-only and SSRF-guarded), and the resolved actor id is stored,
  never the raw input.

  Returns `{:ok, user, remote_actor}` or `{:error, reason}`, where `reason` is
  one of `:invalid_input`, `:not_found`, `:not_a_person`, `:already_added`,
  `:too_many_aliases` or `:moved`.
  """
  @spec add_alias(User.t(), String.t()) ::
          {:ok, User.t(), RemoteActor.t()} | {:error, atom()}
  def add_alias(%User{} = user, input) when is_binary(input) do
    with {:ok, query} <- normalize_input(input),
         {:ok, actor} <- resolve_actor(query),
         :ok <- check_person(actor) do
      Repo.transaction(fn ->
        locked = lock_user(user.id)

        cond do
          moved?(locked) -> Repo.rollback(:moved)
          actor.ap_id in locked.also_known_as -> Repo.rollback(:already_added)
          length(locked.also_known_as) >= @max_aliases -> Repo.rollback(:too_many_aliases)
          true -> update_aliases!(locked, locked.also_known_as ++ [actor.ap_id])
        end
      end)
      |> case do
        {:ok, updated} ->
          Logger.info("account_migration.alias_added: user_id=#{user.id} alias=#{actor.ap_id}")

          Hooks.notify_account_security(user.id, "account_alias_added", %{
            "label" => handle(actor)
          })

          {:ok, updated, actor}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def add_alias(_user, _input), do: {:error, :invalid_input}

  @doc """
  Removes the alias `ap_id` from `user`.

  Returns `{:ok, user}` or `{:error, :not_found}`.
  """
  @spec remove_alias(User.t(), String.t()) :: {:ok, User.t()} | {:error, :not_found}
  def remove_alias(%User{} = user, ap_id) when is_binary(ap_id) do
    Repo.transaction(fn ->
      locked = lock_user(user.id)

      if ap_id in locked.also_known_as do
        update_aliases!(locked, List.delete(locked.also_known_as, ap_id))
      else
        Repo.rollback(:not_found)
      end
    end)
    |> case do
      {:ok, updated} ->
        Logger.info("account_migration.alias_removed: user_id=#{user.id} alias=#{ap_id}")

        Hooks.notify_account_security(user.id, "account_alias_removed", %{
          "label" => alias_label(ap_id)
        })

        {:ok, updated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def remove_alias(_user, _ap_id), do: {:error, :not_found}

  @doc """
  Returns the user's aliases as `%{ap_id: uri, actor: %RemoteActor{} | nil}`
  maps, in the order they were added. The actor is the cached copy, if any; no
  network request is made.
  """
  @spec list_aliases(User.t()) :: [%{ap_id: String.t(), actor: RemoteActor.t() | nil}]
  def list_aliases(%User{} = user) do
    aliases = Repo.get!(User, user.id).also_known_as

    actors =
      from(r in RemoteActor, where: r.ap_id in ^aliases)
      |> Repo.all()
      |> Map.new(&{&1.ap_id, &1})

    Enum.map(aliases, &%{ap_id: &1, actor: Map.get(actors, &1)})
  end

  @doc """
  Returns a display label for an alias: `@user@domain` when the actor is
  cached, otherwise the URI.
  """
  @spec alias_label(String.t()) :: String.t()
  def alias_label(ap_id) when is_binary(ap_id) do
    case Repo.one(from(r in RemoteActor, where: r.ap_id == ^ap_id)) do
      %RemoteActor{} = actor -> handle(actor)
      nil -> ap_id
    end
  end

  defp handle(%RemoteActor{username: username, domain: domain}), do: "@#{username}@#{domain}"

  defp normalize_input(input) do
    query = String.trim(input)

    if query == "" or String.length(query) > @max_input_length or
         String.match?(query, ~r/[\s[:cntrl:]]/u) do
      {:error, :invalid_input}
    else
      {:ok, query}
    end
  end

  # Local actors are refused by ActorResolver (`:self_referencing`) and a
  # local handle resolves to a local actor, so both end up as `:not_found`.
  defp resolve_actor(query) do
    case Federation.lookup_remote_actor(query) do
      {:ok, %RemoteActor{} = actor} ->
        {:ok, actor}

      {:error, :invalid_query} ->
        {:error, :invalid_input}

      {:error, reason} ->
        Logger.info("account_migration.alias_lookup_failed: reason=#{inspect(reason)}")
        {:error, :not_found}
    end
  end

  # Only person accounts can be move targets or sources; boards (Group),
  # instance actors and bots (Service) cannot.
  defp check_person(%RemoteActor{actor_type: "Person"}), do: :ok
  defp check_person(_), do: {:error, :not_a_person}

  defp lock_user(user_id) do
    Repo.one!(from(u in User, where: u.id == ^user_id, lock: "FOR UPDATE"))
  end

  defp update_aliases!(user, aliases) do
    case user |> User.aliases_changeset(aliases) |> Repo.update() do
      {:ok, updated} -> updated
      {:error, _changeset} -> Repo.rollback(:too_many_aliases)
    end
  end
end
