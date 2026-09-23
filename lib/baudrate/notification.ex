defmodule Baudrate.Notification do
  @moduledoc """
  The Notification context manages user notifications.

  Notifications are created when events occur (replies, mentions, likes, follows,
  etc.) and are delivered in real-time via PubSub. Self-notifications are
  suppressed, and notifications from blocked/muted actors are silently dropped.

  Duplicate notifications (same type, actor, article, comment for the same user)
  are deduplicated via unique indexes and return `{:ok, :duplicate}`.
  """

  import Ecto.Query

  require Logger

  alias Baudrate.Auth
  alias Baudrate.Notification.{Notification, PubSub, WebPush}
  alias Baudrate.Repo
  alias Baudrate.Setup.User

  @per_page 20
  @max_per_page 100

  # Account security notices and moderation notices about a member's own
  # content bypass notification preferences.
  @security_types Notification.always_delivered_types()

  @doc """
  Creates a notification for a user.

  Silently skips (returns `{:ok, :skipped}`) when:

    * The recipient is the actor (self-notification)
    * The recipient has blocked or muted the actor
    * The recipient has disabled in-app notifications for this type (never
      for account security notices, see `Notification.security_types/0`)

  Returns `{:ok, :duplicate}` on unique constraint violation (dedup).

  On success, broadcasts `:notification_created` via PubSub and returns
  `{:ok, notification}`.
  """
  @spec create_notification(map()) ::
          {:ok, Notification.t()}
          | {:ok, :skipped}
          | {:ok, :duplicate}
          | {:error, Ecto.Changeset.t()}
  def create_notification(attrs) do
    attrs = normalize_attrs(attrs)

    with :ok <- check_self_notification(attrs),
         :ok <- check_blocked_or_muted(attrs),
         {:ok, user} <- fetch_recipient(attrs),
         :ok <- check_in_app_preference(attrs, user) do
      %Notification{}
      |> Notification.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, notification} ->
          PubSub.broadcast_to_user(
            notification.user_id,
            :notification_created,
            %{notification_id: notification.id}
          )

          maybe_send_push(notification, user)

          {:ok, notification}

        {:error, %Ecto.Changeset{errors: errors} = changeset} ->
          if has_unique_constraint_error?(errors) do
            {:ok, :duplicate}
          else
            {:error, changeset}
          end
      end
    end
  end

  # The group a notification is listed under (6B). Likes and boosts of one
  # thing share a key whoever sent them; every other notification is its own
  # group. `unread_count/1` and `list_notification_groups/2` both use it, so
  # the badge counts what the page shows.
  defmacrop group_key(n) do
    quote do
      fragment(
        "CASE WHEN ? = ANY(?) THEN ? || ':' || coalesce(?, 0) || ':' || coalesce(?, 0) ELSE 'n:' || ? END",
        unquote(n).type,
        type(^Notification.groupable_types(), {:array, :string}),
        unquote(n).type,
        unquote(n).article_id,
        unquote(n).comment_id,
        unquote(n).id
      )
    end
  end

  @doc """
  Returns the count of unread notifications for a user, counting a group of
  likes or boosts of one thing as one — the way the notifications page lists
  them.
  """
  @spec unread_count(integer()) :: non_neg_integer()
  def unread_count(user_id) do
    Repo.one(
      from(n in Notification,
        where: n.user_id == ^user_id and n.read == false,
        select: count(group_key(n), :distinct)
      )
    ) || 0
  end

  @doc """
  Lists a user's notifications as groups, newest first: likes and boosts of
  one article or comment are one entry, and everything else is an entry of
  its own. Pages count groups, so a group never splits across two pages.

  ## Options

    * `:page`, `:per_page` — as `list_notifications/2`
    * `:types` — only these types (a category from
      `Notification.category_types/1`); `nil` for all

  Returns `%{groups: [group], total:, page:, per_page:, total_pages:}`, where a
  group is `%{notification: newest, actors: [up to three newest, preloaded],
  count: n, ids: [every id in the group], unread: boolean}`.
  """
  @spec list_notification_groups(integer(), keyword()) :: map()
  def list_notification_groups(user_id, opts \\ []) do
    {page, per_page, offset} =
      Baudrate.Pagination.paginate_opts(opts, @per_page, max_per_page: @max_per_page)

    base =
      case Keyword.get(opts, :types) do
        nil -> from(n in Notification, where: n.user_id == ^user_id)
        types -> from(n in Notification, where: n.user_id == ^user_id and n.type in ^types)
      end

    grouped =
      from(n in base,
        group_by: group_key(n),
        select: %{
          last_at: max(n.inserted_at),
          last_id: max(n.id),
          unread: fragment("bool_or(NOT ?)", n.read),
          count: count(n.id),
          ids: fragment("array_agg(? ORDER BY ? DESC, ? DESC)", n.id, n.inserted_at, n.id)
        }
      )

    total = Repo.one(from(g in subquery(grouped), select: count()))

    rows =
      Repo.all(
        from(g in subquery(grouped),
          order_by: [desc: g.last_at, desc: g.last_id],
          offset: ^offset,
          limit: ^per_page
        )
      )

    shown_ids = Enum.flat_map(rows, &Enum.take(&1.ids, 3))

    by_id =
      from(n in Notification,
        where: n.id in ^shown_ids,
        preload: [:actor_user, :actor_remote_actor, :article, :comment]
      )
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    groups =
      Enum.map(rows, fn row ->
        members = row.ids |> Enum.take(3) |> Enum.map(&Map.fetch!(by_id, &1))

        %{
          notification: hd(members),
          actors: members,
          count: row.count,
          ids: row.ids,
          unread: row.unread
        }
      end)

    %{
      groups: groups,
      total: total,
      page: page,
      per_page: per_page,
      total_pages: max(ceil(total / per_page), 1)
    }
  end

  @doc """
  Marks read the group `notification` is listed in (see
  `list_notification_groups/2`): for a like or boost, every unread one of
  that type on the same article and comment; otherwise just this one.

  The group is recomputed here from the stored row, never taken as a list of
  ids from the client. Broadcasts `:notification_read` once when anything
  changed, and returns how many rows it marked.
  """
  @spec mark_group_as_read(Notification.t()) :: non_neg_integer()
  def mark_group_as_read(%Notification{user_id: user_id} = notification) do
    query =
      if notification.type in Notification.groupable_types() do
        from(n in Notification,
          where: n.user_id == ^user_id and n.type == ^notification.type and n.read == false,
          where: coalesce(n.article_id, 0) == ^(notification.article_id || 0),
          where: coalesce(n.comment_id, 0) == ^(notification.comment_id || 0)
        )
      else
        from(n in Notification, where: n.id == ^notification.id and n.read == false)
      end

    {count, _} = Repo.update_all(query, set: [read: true])

    if count > 0 do
      PubSub.broadcast_to_user(user_id, :notification_read, %{notification_id: notification.id})
    end

    count
  end

  @doc """
  Lists notifications for a user, ordered newest first.

  ## Options

    * `:page` — page number (default 1)
    * `:per_page` — items per page (default #{@per_page}, max #{@max_per_page})
  """
  @spec list_notifications(integer(), keyword()) :: map()
  def list_notifications(user_id, opts \\ []) do
    alias Baudrate.Pagination

    pagination = Pagination.paginate_opts(opts, @per_page, max_per_page: @max_per_page)

    from(n in Notification, where: n.user_id == ^user_id)
    |> Pagination.paginate_query(pagination,
      result_key: :notifications,
      order_by: [desc: dynamic([n], n.inserted_at), desc: dynamic([n], n.id)],
      preloads: [:actor_user, :actor_remote_actor, :article, :comment]
    )
  end

  @doc """
  Marks a single notification as read.

  Returns `{:ok, notification}` or `{:error, changeset}`.
  Broadcasts `:notification_read` on success.
  """
  @spec mark_as_read(Notification.t()) :: {:ok, Notification.t()} | {:error, Ecto.Changeset.t()}
  def mark_as_read(%Notification{} = notification) do
    notification
    |> Notification.changeset(%{read: true})
    |> Repo.update()
    |> case do
      {:ok, notification} ->
        PubSub.broadcast_to_user(
          notification.user_id,
          :notification_read,
          %{notification_id: notification.id}
        )

        {:ok, notification}

      error ->
        error
    end
  end

  @doc """
  Marks all unread notifications for a user as read.

  Returns `{count, nil}` where `count` is the number of updated rows.
  Broadcasts `:notifications_all_read` on success.
  """
  @spec mark_all_as_read(integer()) :: {non_neg_integer(), nil}
  def mark_all_as_read(user_id) do
    {count, _} =
      from(n in Notification,
        where: n.user_id == ^user_id and n.read == false
      )
      |> Repo.update_all(set: [read: true])

    if count > 0 do
      PubSub.broadcast_to_user(
        user_id,
        :notifications_all_read,
        %{user_id: user_id}
      )
    end

    {count, nil}
  end

  @doc """
  Deletes notifications older than the given number of days.

  Returns `{count, nil}` where `count` is the number of deleted rows.
  """
  @spec cleanup_old_notifications(pos_integer()) :: {non_neg_integer(), nil}
  def cleanup_old_notifications(days \\ 90) do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-days, :day)
      |> DateTime.truncate(:second)

    from(n in Notification, where: n.inserted_at < ^cutoff)
    |> Repo.delete_all()
  end

  @doc """
  Creates an admin announcement notification for all users with the given role
  or higher.

  The `message` is stored in `data.message`. The `admin` is the acting user.
  Returns a list of `{:ok, notification}` / `{:ok, :skipped}` / `{:ok, :duplicate}`
  results.
  """
  @spec create_admin_announcement(User.t(), String.t()) :: [
          {:ok, Notification.t()}
          | {:ok, :skipped}
          | {:ok, :duplicate}
          | {:error, Ecto.Changeset.t()}
        ]
  def create_admin_announcement(%User{} = admin, message) when is_binary(message) do
    user_ids =
      from(u in User, select: u.id)
      |> Repo.all()

    Enum.map(user_ids, fn user_id ->
      create_notification(%{
        type: "admin_announcement",
        user_id: user_id,
        actor_user_id: admin.id,
        data: %{"message" => message}
      })
    end)
  end

  @doc """
  Gets a notification by ID.

  Returns `nil` if not found.
  """
  @spec get_notification(integer()) :: Notification.t() | nil
  def get_notification(id) do
    Notification
    |> Repo.get(id)
    |> Repo.preload([:actor_user, :actor_remote_actor, :article, :comment])
  end

  @doc """
  Gets a notification by ID, raising if not found.
  """
  def get_notification!(id) do
    Notification
    |> Repo.get!(id)
    |> Repo.preload([:actor_user, :actor_remote_actor, :article, :comment])
  end

  # --- Private helpers ---

  defp normalize_attrs(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp check_self_notification(%{user_id: user_id, actor_user_id: actor_user_id})
       when not is_nil(actor_user_id) and user_id == actor_user_id do
    {:ok, :skipped}
  end

  defp check_self_notification(_attrs), do: :ok

  defp check_blocked_or_muted(%{user_id: user_id, actor_user_id: actor_user_id})
       when not is_nil(actor_user_id) do
    recipient = %User{id: user_id}
    actor = %User{id: actor_user_id}

    if Auth.blocked?(recipient, actor) or Auth.muted?(recipient, actor) do
      {:ok, :skipped}
    else
      :ok
    end
  end

  defp check_blocked_or_muted(%{user_id: user_id, actor_remote_actor_id: remote_id})
       when not is_nil(remote_id) do
    alias Baudrate.Federation.RemoteActor

    case Repo.get(RemoteActor, remote_id) do
      %RemoteActor{ap_id: ap_id, domain: domain} ->
        recipient = %User{id: user_id}

        # A muted server counts as a muted account from it (ADR 0073).
        if Auth.blocked?(recipient, ap_id) or Auth.muted?(recipient, ap_id) or
             domain in Auth.muted_domains(recipient) do
          {:ok, :skipped}
        else
          :ok
        end

      nil ->
        :ok
    end
  end

  defp check_blocked_or_muted(_attrs), do: :ok

  defp fetch_recipient(%{user_id: user_id}) when not is_nil(user_id) do
    case Repo.get(User, user_id) do
      %User{} = user -> {:ok, user}
      nil -> {:ok, nil}
    end
  end

  defp fetch_recipient(_attrs), do: {:ok, nil}

  # Account security notices are always delivered. `User.notification_preferences_changeset/2`
  # already rejects these keys, but a stored preference must not be able to
  # silence a warning about a second-factor change either.
  defp check_in_app_preference(%{type: type}, _user)
       when type in @security_types,
       do: :ok

  defp check_in_app_preference(%{type: type}, %User{notification_preferences: prefs})
       when is_binary(type) and is_map(prefs) do
    case get_in(prefs, [type, "in_app"]) do
      false -> {:ok, :skipped}
      _ -> :ok
    end
  end

  defp check_in_app_preference(_attrs, _user), do: :ok

  defp has_unique_constraint_error?(errors) do
    Enum.any?(errors, fn
      {_field, {_msg, opts}} -> Keyword.get(opts, :constraint) in [:unique]
      _ -> false
    end)
  end

  defp maybe_send_push(%Notification{} = notification, user) do
    if web_push_enabled_for?(user, notification.type) do
      schedule_push_delivery(notification)
    end
  end

  defp web_push_enabled_for?(_user, type) when type in @security_types,
    do: true

  defp web_push_enabled_for?(%User{notification_preferences: prefs}, type)
       when is_map(prefs) and is_binary(type) do
    get_in(prefs, [type, "web_push"]) != false
  end

  defp web_push_enabled_for?(_user, _type), do: true

  defp schedule_push_delivery(notification) do
    if Application.get_env(:baudrate, :web_push_async, true) do
      Task.Supervisor.start_child(
        Baudrate.Federation.TaskSupervisor,
        fn -> WebPush.deliver_notification(notification) end
      )
    else
      WebPush.deliver_notification(notification)
    end
  end
end
