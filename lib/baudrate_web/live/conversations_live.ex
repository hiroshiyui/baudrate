defmodule BaudrateWeb.ConversationsLive do
  @moduledoc """
  LiveView for the conversations list page (`/messages`).

  Displays all conversations for the current user, ordered by most recent
  message, with unread badges. Subscribes to user-level DM PubSub events for
  real-time updates (`:dm_received` and `:dm_read`).

  `?q=` searches the member's own conversations (`Messaging.search_messages/3`,
  ADR 0071) — never anyone else's, and never through the site search. Each
  new query takes a place in the search rate limit; paging through its
  results does not. A result opens the conversation on the message it found
  (`/messages/:id?around=…`).
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Auth
  alias Baudrate.Messaging
  alias Baudrate.Messaging.PubSub, as: MessagingPubSub
  alias BaudrateWeb.RateLimits
  import BaudrateWeb.Helpers, only: [participant_name: 1, format_relative_time: 1, parse_page: 1]

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
      |> assign(:live_status, "")
      |> assign(:query, "")
      |> assign(:results, nil)
      |> assign(:search_status, "")

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    query = params |> Map.get("q", "") |> String.trim() |> String.slice(0, 200)
    page = parse_page(params["page"])

    cond do
      query == "" ->
        {:noreply,
         socket |> assign(:query, "") |> assign(:results, nil) |> assign(:search_status, "")}

      # A new query costs a place in the search limit; turning the page does not.
      query != socket.assigns.query and
          RateLimits.check_search(socket.assigns.current_user.id) != :ok ->
        {
          :noreply,
          # The refused query is not remembered, so asking for it again is
          # another new query rather than a free page turn.
          socket
          |> assign(:results, nil)
          |> put_flash(:error, gettext("Too many searches. Please wait a moment and try again."))
        }

      true ->
        results = Messaging.search_messages(socket.assigns.current_user, query, page: page)

        {:noreply,
         socket
         |> assign(:query, query)
         |> assign(:results, results)
         |> assign(
           :search_status,
           ngettext("%{count} message found", "%{count} messages found", results.total,
             count: results.total
           )
         )}
    end
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, push_patch(socket, to: ~p"/messages?#{[q: q]}")}
  end

  @impl true
  def handle_info({event, _payload}, socket) when event in [:dm_received, :dm_read] do
    user = socket.assigns.current_user
    conversations = Messaging.list_conversations(user)
    unread_counts = load_unread_counts(conversations, user)
    muted_convs = load_muted_conversations(conversations, user)

    {:noreply,
     socket
     |> assign(:conversations, conversations)
     |> assign(:unread_counts, unread_counts)
     |> assign(:muted_conversations, muted_convs)
     |> assign(:live_status, unread_status(unread_counts, muted_convs))}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # Announced through the page's `role="status"` node so screen-reader users
  # learn about incoming messages that silently re-render the list.
  defp unread_status(unread_counts, muted_convs) do
    count =
      unread_counts
      |> Enum.reject(fn {conv_id, _} -> Map.get(muted_convs, conv_id, false) end)
      |> Enum.map(fn {_, n} -> n end)
      |> Enum.sum()

    ngettext("%{count} unread message", "%{count} unread messages", count, count: count)
  end

  defp load_unread_counts(conversations, user) do
    conversation_ids = Enum.map(conversations, & &1.id)
    Messaging.unread_counts_for_conversations(conversation_ids, user)
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

  # A plain-text excerpt around the first match, so a long message shows the
  # part that was searched for.
  defp excerpt(body, query) do
    text = (body || "") |> Baudrate.Sanitizer.Native.strip_tags() |> String.replace(~r/\s+/u, " ")

    # A case-insensitive Unicode match reports offsets in `text` itself;
    # downcasing first can change byte lengths outside ASCII.
    case Regex.run(~r/#{Regex.escape(query)}/iu, text, return: :index) do
      [{byte_pos, _} | _] ->
        prefix = binary_part(text, 0, byte_pos)
        start = max(String.length(prefix) - 60, 0)
        snippet = String.slice(text, start, 200)
        if(start > 0, do: "…", else: "") <> snippet

      nil ->
        String.slice(text, 0, 200)
    end
  end

  defp sender_label(%{sender_user: %Baudrate.Setup.User{} = user}, current_user) do
    if user.id == current_user.id, do: gettext("You"), else: participant_name(user)
  end

  defp sender_label(%{sender_remote_actor: %{} = actor}, _current_user),
    do: participant_name(actor)

  defp sender_label(_message, _current_user), do: ""

  defp other_participant(conv, current_user) do
    Messaging.other_participant(conv, current_user)
  end
end
