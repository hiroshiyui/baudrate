defmodule BaudrateWeb.NotificationsLive do
  @moduledoc """
  LiveView for the notifications page (`/notifications`).

  Displays a paginated list of notifications for the current user, ordered
  newest first. Users can mark individual notifications as read or mark all
  as read. Subscribes to `Notification.PubSub` for real-time updates.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Notification
  alias Baudrate.Notification.PubSub, as: NotificationPubSub

  import BaudrateWeb.Helpers,
    only: [
      parse_page: 1,
      notification_text: 1,
      notification_icon: 1,
      translate_report_category: 1,
      translate_health_check: 1,
      format_relative_time: 1,
      parse_id: 1
    ]

  # Account security notices link to /profile; moderation notices do not, so
  # this is deliberately the security list, not always_delivered_types/0.
  @security_types Baudrate.Notification.Notification.security_types()

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if connected?(socket) do
      NotificationPubSub.subscribe_user(user.id)
    end

    {:ok, assign(socket, page_title: gettext("Notifications"), live_status: "")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # An unknown filter is ignored rather than refused: it is a bookmark or a
    # hand-edited URL, and showing everything is the harmless answer.
    filter =
      if Notification.Notification.category_types(params["filter"]),
        do: params["filter"]

    socket =
      socket
      |> assign(:filter, filter)
      |> load_groups(parse_page(params["page"]))

    {:noreply, socket}
  end

  @impl true
  def handle_info({event, _payload}, socket)
      when event in [:notification_created, :notification_read, :notifications_all_read] do
    user = socket.assigns.current_user

    {:noreply,
     socket
     |> load_groups(socket.assigns.page)
     |> maybe_announce(event, user.id)}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("mark_read", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    user_id = user.id

    notification =
      case parse_id(id) do
        {:ok, notification_id} -> Notification.get_notification(notification_id)
        :error -> nil
      end

    # A like or boost stands for its whole group on the page, so marking it
    # marks the group — worked out from the stored row, not from the client.
    case notification do
      %{user_id: ^user_id} = notif ->
        Notification.mark_group_as_read(notif)

      _ ->
        :ok
    end

    {:noreply, socket}
  end

  def handle_event("mark_all_read", _params, socket) do
    user = socket.assigns.current_user
    Notification.mark_all_as_read(user.id)
    {:noreply, socket}
  end

  # Screen readers do not notice a silently re-rendered list, so a newly
  # arrived notification is announced through the page's `role="status"` node.
  defp maybe_announce(socket, :notification_created, user_id) do
    count = Notification.unread_count(user_id)

    assign(
      socket,
      :live_status,
      ngettext(
        "New notification. %{count} unread notification",
        "New notification. %{count} unread notifications",
        count,
        count: count
      )
    )
  end

  defp maybe_announce(socket, _event, _user_id), do: socket

  defp load_groups(socket, page) do
    user = socket.assigns.current_user

    types =
      socket.assigns.filter && Notification.Notification.category_types(socket.assigns.filter)

    result = Notification.list_notification_groups(user.id, page: page, types: types)

    socket
    |> assign(:groups, result.groups)
    |> assign(:page, result.page)
    |> assign(:total_pages, result.total_pages)
  end

  defp filters do
    [
      {nil, gettext("All")},
      {"discussion", gettext("Replies and mentions")},
      {"reactions", gettext("Likes and boosts")},
      {"follows", gettext("Follow activity")},
      {"moderation", gettext("Moderation and site")},
      {"account", gettext("Account")}
    ]
  end

  defp filter_path(nil), do: ~p"/notifications"
  defp filter_path(key), do: ~p"/notifications?#{[filter: key]}"

  defp page_params(nil), do: %{}
  defp page_params(filter), do: %{"filter" => filter}

  # The actors named in a group's line: all of them when there are one or
  # two, otherwise the two newest and a count of the rest.
  defp shown_actors(%{count: count, actors: actors}) when count <= 2, do: actors
  defp shown_actors(%{actors: actors}), do: Enum.take(actors, 2)

  defp other_count(group), do: group.count - length(shown_actors(group))

  defp actor_name(%{actor_user: %{username: _} = user}),
    do: BaudrateWeb.Helpers.display_name(user)

  defp actor_name(%{actor_remote_actor: %{username: u, domain: d}}), do: "#{u}@#{d}"
  defp actor_name(_), do: nil

  defp actor_link(%{actor_user: %Baudrate.Setup.User{} = user}),
    do: BaudrateWeb.Helpers.author_path(user)

  defp actor_link(_), do: nil

  # A comment is linked on the page it is on, for this reader — a bare
  # `#comment-N` only works when the comment is on page 1.
  defp target_link(%{article: %{slug: slug} = article, comment: %{} = comment}, viewer)
       when not is_nil(slug),
       do: BaudrateWeb.Helpers.comment_link(article, comment, viewer)

  defp target_link(%{type: "poll_closed", article: %{slug: slug}}, _viewer)
       when not is_nil(slug),
       do: ~p"/articles/#{slug}" <> "#article-poll"

  defp target_link(notif, _viewer), do: target_link(notif)

  defp target_link(%{article: %{slug: slug}}) when not is_nil(slug), do: ~p"/articles/#{slug}"
  defp target_link(%{type: "held_post"}), do: ~p"/moderation/held"
  defp target_link(%{type: "bot_disabled"}), do: ~p"/admin/bots"
  defp target_link(%{type: "follow_request"}), do: ~p"/followers"
  defp target_link(%{type: "post_rejected"}), do: ~p"/drafts"
  defp target_link(%{type: "data_export_" <> _}), do: ~p"/profile/export"
  defp target_link(%{type: "totp_login_failed"}), do: ~p"/profile/password"
  defp target_link(%{type: "account_deletion_" <> _}), do: ~p"/profile/account"
  defp target_link(%{type: "account_" <> _}), do: ~p"/profile/move"
  defp target_link(%{type: type}) when type in @security_types, do: ~p"/profile/security"
  defp target_link(_), do: nil

  defp target_title(%{article: %{title: title}}) when not is_nil(title), do: title
  defp target_title(%{type: "admin_announcement", data: %{"message" => msg}}), do: msg

  defp target_title(%{type: "actor_moved", data: %{"label" => label}}) when label != "",
    do: gettext("New account: %{label}", label: label)

  defp target_title(%{type: "board_actor_moved", data: %{"label" => label, "boards" => boards}})
       when is_list(boards),
       do:
         gettext("New account: %{label}. Boards: %{boards}",
           label: label,
           boards: Enum.join(boards, ", ")
         )

  defp target_title(%{type: type, data: %{"label" => label}})
       when type in ["security_key_added", "security_key_removed"] and label != "",
       do: gettext("Security key: %{label}", label: label)

  defp target_title(%{type: type, data: %{"label" => label}})
       when type in ["account_alias_added", "account_alias_removed"] and label != "",
       do: gettext("Alias: %{label}", label: label)

  defp target_title(%{type: "account_move_" <> _, data: %{"label" => label}}) when label != "",
    do: gettext("Destination: %{label}", label: label)

  defp target_title(%{type: "held_post"}), do: gettext("Review held posts")

  defp target_title(%{type: "bot_disabled", data: %{"username" => username}}),
    do: gettext("Review bot @%{username}", username: username)

  defp target_title(%{type: "post_rejected"}), do: gettext("See what you wrote")
  defp target_title(%{type: "data_export_" <> _}), do: gettext("Review your data exports")
  defp target_title(%{type: "totp_login_failed"}), do: gettext("Change your password")

  defp target_title(%{type: type}) when type in @security_types,
    do: gettext("Review your security settings")

  defp target_title(_), do: nil

  defp security_notice?(%{type: type}), do: type in @security_types

  # This notice is not about a change the user made, so the usual hint does not fit.
  defp security_hint(%{type: "totp_login_failed"}),
    do:
      gettext(
        "If this was not you, your password is known to someone else. Change it right away and contact an administrator."
      )

  defp security_hint(_),
    do:
      gettext(
        "If you did not make this change, check your security settings right away and contact an administrator."
      )
end
