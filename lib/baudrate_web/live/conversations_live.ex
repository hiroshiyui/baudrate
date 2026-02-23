defmodule BaudrateWeb.ConversationsLive do
  @moduledoc """
  LiveView for the conversations list page (`/messages`).

  Displays all conversations for the current user, ordered by most recent
  message. Shows unread badges and the last message snippet. Subscribes
  to user-level DM PubSub events for real-time updates.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Auth
  alias Baudrate.Messaging
  alias Baudrate.Messaging.PubSub, as: MessagingPubSub

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if connected?(socket) do
      MessagingPubSub.subscribe_user(user.id)
    end

    conversations = Messaging.list_conversations(user)
    unread_counts = load_unread_counts(conversations, user)
    muted_convs = load_muted_conversations(conversations, user)

    socket =
      socket
      |> assign(:conversations, conversations)
      |> assign(:unread_counts, unread_counts)
      |> assign(:muted_conversations, muted_convs)
      |> assign(:page_title, gettext("Messages"))

    {:ok, socket}
  end

  @impl true
  def handle_info({:dm_received, _payload}, socket) do
    user = socket.assigns.current_user
    conversations = Messaging.list_conversations(user)
    unread_counts = load_unread_counts(conversations, user)
    muted_convs = load_muted_conversations(conversations, user)

    {:noreply,
     socket
     |> assign(:conversations, conversations)
     |> assign(:unread_counts, unread_counts)
     |> assign(:muted_conversations, muted_convs)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_unread_counts(conversations, user) do
    Map.new(conversations, fn conv ->
      {conv.id, Messaging.unread_count_for_conversation(conv.id, user)}
    end)
  end

  defp load_muted_conversations(conversations, user) do
    muted_uids = MapSet.new(Auth.muted_user_ids(user))
    muted_ap_ids = MapSet.new(Auth.muted_actor_ap_ids(user))

    Map.new(conversations, fn conv ->
      other = Messaging.other_participant(conv, user)

      muted =
        case other do
          %Baudrate.Setup.User{id: id} -> MapSet.member?(muted_uids, id)
          %Baudrate.Federation.RemoteActor{ap_id: ap_id} -> MapSet.member?(muted_ap_ids, ap_id)
          _ -> false
        end

      {conv.id, muted}
    end)
  end

  defp other_participant(conv, current_user) do
    Messaging.other_participant(conv, current_user)
  end

  defp participant_name(%Baudrate.Setup.User{} = user), do: user.username

  defp participant_name(%Baudrate.Federation.RemoteActor{} = actor),
    do: "#{actor.username}@#{actor.domain}"

  defp participant_name(_), do: "?"

  defp format_relative_time(datetime) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, datetime, :second)

    cond do
      diff < 60 -> gettext("just now")
      diff < 3600 -> gettext("%{count}m ago", count: div(diff, 60))
      diff < 86_400 -> gettext("%{count}h ago", count: div(diff, 3600))
      diff < 604_800 -> gettext("%{count}d ago", count: div(diff, 86_400))
      true -> Calendar.strftime(datetime, "%Y-%m-%d")
    end
  end
end
