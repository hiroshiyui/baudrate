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

  @doc """
  Creates a notification for a user.

  Silently skips (returns `{:ok, :skipped}`) when:

    * The recipient is the actor (self-notification)
    * The recipient has blocked or muted the actor
    * The recipient has disabled in-app notifications for this type

  Returns `{:ok, :duplicate}` on unique constraint violation (dedup).

  On success, broadcasts `:notification_created` via PubSub and returns
  `{:ok, notification}`.
  """
  def create_notification(attrs) do
    attrs = normalize_attrs(attrs)

    with :ok <- check_self_notification(attrs),
         :ok <- check_blocked_or_muted(attrs),
         :ok <- check_in_app_preference(attrs) do
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

          maybe_send_push(notification)

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

  @doc """
  Returns the count of unread notifications for a user.
  """
  def unread_count(user_id) do
    Repo.one(
      from(n in Notification,
        where: n.user_id == ^user_id and n.read == false,
        select: count(n.id)
      )
    ) || 0
  end

  @doc """
  Lists notifications for a user, ordered newest first.

  ## Options

    * `:page` — page number (default 1)
    * `:per_page` — items per page (default #{@per_page})
  """
  def list_notifications(user_id, opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    per_page = Keyword.get(opts, :per_page, @per_page)
    offset = (page - 1) * per_page

    notifications =
      from(n in Notification,
        where: n.user_id == ^user_id,
        order_by: [desc: n.inserted_at, desc: n.id],
        offset: ^offset,
        limit: ^per_page,
        preload: [:actor_user, :actor_remote_actor, :article, :comment]
      )
      |> Repo.all()

    total = Repo.one(from(n in Notification, where: n.user_id == ^user_id, select: count(n.id)))
    total_pages = max(ceil(total / per_page), 1)

    %{notifications: notifications, page: page, total_pages: total_pages}
  end

  @doc """
  Marks a single notification as read.

  Returns `{:ok, notification}` or `{:error, changeset}`.
  Broadcasts `:notification_read` on success.
  """
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

  defp check_blocked_or_muted(_attrs), do: :ok

  defp check_in_app_preference(%{type: type, user_id: user_id}) when is_binary(type) do
    case Repo.get(User, user_id) do
      %User{notification_preferences: prefs} when is_map(prefs) ->
        case get_in(prefs, [type, "in_app"]) do
          false -> {:ok, :skipped}
          _ -> :ok
        end

      _ ->
        :ok
    end
  end

  defp check_in_app_preference(_attrs), do: :ok

  defp has_unique_constraint_error?(errors) do
    Enum.any?(errors, fn
      {_field, {_msg, opts}} -> Keyword.get(opts, :constraint) in [:unique]
      _ -> false
    end)
  end

  defp maybe_send_push(%Notification{} = notification) do
    if web_push_enabled_for?(notification.user_id, notification.type) do
      schedule_push_delivery(notification)
    end
  end

  defp web_push_enabled_for?(user_id, type) when is_binary(type) do
    case Repo.get(User, user_id) do
      %User{notification_preferences: prefs} when is_map(prefs) ->
        get_in(prefs, [type, "web_push"]) != false

      _ ->
        true
    end
  end

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
