defmodule BaudrateWeb.ConversationLive do
  @moduledoc """
  LiveView for a single conversation thread (`/messages/:id` or `/messages/new?to=username`).

  Displays messages as bubbles with sender alignment, supports sending new
  messages, deleting own messages, and auto-marks messages as read. Each
  received message can be reported (only that message's text reaches the
  moderators), and a conversation with a remote actor has a menu to mute,
  block or report the actor (`BaudrateWeb.SafetyActions`).
  Subscribes to conversation-level PubSub for real-time updates.

  When navigated to `/messages/new` without a `?to=` param, renders a
  recipient selection UI with live-search. Selecting a user navigates
  to `/messages/new?to=<username>` to start the conversation.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Auth
  alias Baudrate.Messaging
  alias Baudrate.Messaging.PubSub, as: MessagingPubSub
  alias BaudrateWeb.RateLimits
  alias BaudrateWeb.SafetyActions
  import BaudrateWeb.Helpers, only: [parse_id: 1, participant_name: 1]

  # Messages loaded when the page opens, and per "Load older messages" click.
  @page_size 100
  # Upper bound on messages kept in the socket during one long session.
  @max_loaded 1_000

  @impl true
  def mount(params, _session, socket) do
    user = socket.assigns.current_user

    case resolve_conversation(params, user) do
      {:ok, conversation, other} ->
        mount_conversation(socket, user, conversation, other, params)

      {:new, recipient} ->
        mount_new_conversation(socket, user, recipient)

      :select_recipient ->
        mount_recipient_selection(socket)

      {:error, reason} ->
        {:ok,
         socket
         |> put_flash(:error, error_message(reason))
         |> redirect(to: ~p"/messages")}
    end
  end

  defp mount_conversation(socket, user, conversation, other, params) do
    if connected?(socket) do
      MessagingPubSub.subscribe_conversation(conversation.id)
    end

    # `?around=<message id>` opens on a search result (6D). `list_messages`
    # scopes the window to this conversation, so a foreign id finds nothing.
    {messages, found_id} =
      case parse_id(params["around"]) do
        {:ok, around_id} ->
          window = Messaging.list_messages(conversation, around_id: around_id, max: @max_loaded)
          found = if Enum.any?(window, &(&1.id == around_id)), do: around_id
          {window, found}

        :error ->
          {Messaging.list_messages(conversation, limit: @page_size), nil}
      end

    mark_read(conversation, user, messages)

    socket =
      socket
      |> assign(:mode, :conversation)
      |> assign(:conversation, conversation)
      |> assign_messages(messages)
      |> assign(:other_participant, other)
      |> assign(:new_conversation, false)
      |> assign(:page_title, participant_name(other))
      |> assign(:message_form, to_form(%{"body" => ""}, as: :message))
      |> assign(:history_announcement, "")
      |> assign(:found_message_id, found_id)
      |> assign_other_safety_state()
      |> SafetyActions.assign_report_modal()
      |> allow_dm_images(other)

    {:ok, socket}
  end

  # Images only between members here (ADR 0071): a conversation with an
  # account on another server gets no upload at all.
  defp allow_dm_images(socket, %Baudrate.Setup.User{}) do
    socket
    |> assign(:images_allowed, true)
    |> assign(:uploaded_dm_images, [])
    |> allow_upload(:dm_images,
      accept: ~w(.jpg .jpeg .png .webp .gif),
      max_entries: Baudrate.Messaging.DmImage.max_per_message(),
      max_file_size: 8_000_000,
      auto_upload: true,
      progress: &handle_dm_image_progress/3
    )
  end

  defp allow_dm_images(socket, _remote) do
    socket
    |> assign(:images_allowed, false)
    |> assign(:uploaded_dm_images, [])
  end

  defp mount_new_conversation(socket, user, recipient) do
    case Messaging.dm_permission(user, recipient) do
      :ok ->
        socket =
          socket
          |> assign(:mode, :new_conversation)
          |> assign(:conversation, nil)
          |> assign(:messages, [])
          |> assign(:has_older_messages, false)
          |> assign(:other_participant, recipient)
          |> assign(:new_conversation, true)
          |> assign(:page_title, gettext("New Message"))
          |> assign(:message_form, to_form(%{"body" => ""}, as: :message))
          |> assign(:history_announcement, "")
          |> assign(:found_message_id, nil)
          |> allow_dm_images(recipient)

        {:ok, socket}

      {:error, reason} ->
        {:ok,
         socket
         |> put_flash(:error, send_refusal(reason, user))
         |> redirect(to: ~p"/messages")}
    end
  end

  defp mount_recipient_selection(socket) do
    socket =
      socket
      |> assign(:mode, :select_recipient)
      |> assign(:search_query, "")
      |> assign(:search_results, [])
      |> assign(:page_title, gettext("New Message"))

    {:ok, socket}
  end

  @impl true
  def handle_event("send_message", %{"message" => %{"body" => body}}, socket) do
    user = socket.assigns.current_user
    body = String.trim(body)
    image_ids = Enum.map(socket.assigns.uploaded_dm_images, & &1.id)

    # A photo sent on its own is a whole message (ADR 0071); an empty
    # composer with nothing attached is not.
    if body == "" and image_ids == [] do
      {:noreply, assign(socket, :message_form, to_form(%{"body" => ""}, as: :message))}
    else
      socket = ensure_conversation(socket, user)
      conversation = socket.assigns.conversation

      case RateLimits.check_dm_send(user.id) do
        :ok ->
          case Messaging.create_message(conversation, user, %{body: body, image_ids: image_ids}) do
            {:ok, message} ->
              messages =
                (socket.assigns.messages ++ [Messaging.get_message(message.id)])
                |> Enum.take(-@max_loaded)

              mark_read(conversation, user, messages)

              {:noreply,
               socket
               |> assign_messages(messages)
               |> assign(:uploaded_dm_images, [])
               |> assign(:message_form, to_form(%{"body" => ""}, as: :message))
               |> assign(:history_announcement, "")}

            {:error, reason} when is_atom(reason) ->
              {:noreply, put_flash(socket, :error, send_refusal(reason, user))}

            {:error, _changeset} ->
              {:noreply, put_flash(socket, :error, gettext("Failed to send message."))}
          end

        {:error, :rate_limited} ->
          {:noreply, put_flash(socket, :error, gettext("Too many messages. Please slow down."))}
      end
    end
  end

  # The description saves itself against the uploaded row, not with the form
  # (ADR 0061); it is the uploader's own and is never screened (ADR 0065).
  @impl true
  def handle_event("save_dm_image_alt", %{"id" => id} = params, socket) do
    with %{} = user <- socket.assigns.current_user,
         {:ok, image_id} <- parse_id(id),
         {:ok, image} <-
           Messaging.set_dm_image_alt(user, image_id, %{"alt" => params["value"]}) do
      images =
        Enum.map(socket.assigns.uploaded_dm_images, fn i ->
          if i.id == image.id, do: image, else: i
        end)

      {:noreply, assign(socket, :uploaded_dm_images, images)}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("remove_dm_image", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with {:ok, image_id} <- parse_id(id),
         true <- Enum.any?(socket.assigns.uploaded_dm_images, &(&1.id == image_id)),
         :ok <- Messaging.delete_unsent_dm_image(user, image_id) do
      {:noreply,
       assign(
         socket,
         :uploaded_dm_images,
         Enum.reject(socket.assigns.uploaded_dm_images, &(&1.id == image_id))
       )}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_dm_image_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :dm_images, ref)}
  end

  @impl true
  def handle_event("validate_dm_images", _params, socket), do: {:noreply, socket}

  # Tracks the composer's in-progress text in the form assign so that the
  # reset after a successful send is a real diff ("typed text" -> "") and the
  # input is cleared without remounting the form (a remount loses focus).
  @impl true
  def handle_event("update_message", %{"message" => %{"body" => body}}, socket) do
    {:noreply, assign(socket, :message_form, to_form(%{"body" => body}, as: :message))}
  end

  @impl true
  def handle_event("search_recipient", %{"search" => %{"query" => query}}, socket) do
    query = String.trim(query)

    if String.length(query) < 2 do
      {:noreply, socket |> assign(:search_query, query) |> assign(:search_results, [])}
    else
      user = socket.assigns.current_user
      results = Auth.search_users(query, exclude_id: user.id)
      {:noreply, socket |> assign(:search_query, query) |> assign(:search_results, results)}
    end
  end

  @impl true
  def handle_event("select_recipient", %{"username" => username}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/messages/new?to=#{username}")}
  end

  @impl true
  def handle_event("load_older", _params, socket) do
    case socket.assigns do
      %{conversation: %{} = conversation, messages: [oldest | _] = messages} ->
        older = Messaging.list_messages(conversation, before_id: oldest.id, limit: @page_size)
        loaded = Enum.take(older ++ messages, @max_loaded)
        added = length(loaded) - length(messages)

        {:noreply,
         socket
         |> assign_messages(loaded)
         # Announced as a count, because the messages themselves are no longer
         # inside the live region — reading twenty of them aloud took the page
         # away from a screen-reader user for as long as it lasted.
         |> assign(
           :history_announcement,
           ngettext(
             "%{count} earlier message loaded",
             "%{count} earlier messages loaded",
             added,
             count: added
           )
         )}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("delete_message", %{"id" => id}, socket) do
    case parse_id(id) do
      :error -> {:noreply, socket}
      {:ok, msg_id} -> do_delete_message(socket, msg_id)
    end
  end

  @impl true
  def handle_event("open_report_modal", params, socket),
    do: {:noreply, SafetyActions.open_report_modal(socket, params)}

  @impl true
  def handle_event("close_report_modal", _params, socket),
    do: {:noreply, SafetyActions.assign_report_modal(socket)}

  @impl true
  def handle_event("submit_report", %{"reason" => _} = params, socket),
    do: {:noreply, SafetyActions.submit_report(socket, params)}

  # The conversation stays on screen after these, so the menu switches to the
  # matching undo control and keeps focus on its toggle.
  @impl true
  def handle_event(event, %{"id" => id}, socket)
      when event in ~w(block_remote_actor unblock_remote_actor mute_remote_actor unmute_remote_actor) do
    action =
      case event do
        "block_remote_actor" -> :block
        "unblock_remote_actor" -> :unblock
        "mute_remote_actor" -> :mute
        "unmute_remote_actor" -> :unmute
      end

    {_result, socket} = SafetyActions.remote_actor_action(socket, action, id)

    {:noreply,
     socket
     |> assign_other_safety_state()
     |> push_event("focus", %{id: "conversation-actions-menu-toggle"})}
  end

  defp do_delete_message(socket, msg_id) do
    user = socket.assigns.current_user

    case Messaging.get_message(msg_id) do
      nil ->
        {:noreply, socket}

      message ->
        case Messaging.soft_delete_message(message, user) do
          {:ok, _} ->
            {:noreply, reload_messages(socket)}

          {:error, :unauthorized} ->
            {:noreply,
             put_flash(socket, :error, gettext("You can only delete your own messages."))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to delete message."))}
        end
    end
  end

  @impl true
  def handle_info({:dm_message_created, %{message_id: message_id}}, socket) do
    user = socket.assigns.current_user
    message = Messaging.get_message(message_id)

    if message && message.sender_user_id != user.id do
      messages = (socket.assigns.messages ++ [message]) |> Enum.take(-@max_loaded)
      mark_read(socket.assigns.conversation, user, messages)
      {:noreply, assign_messages(socket, messages)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:dm_message_deleted, _payload}, socket) do
    {:noreply, reload_messages(socket)}
  end

  @impl true
  def handle_info({:link_preview_fetched, _payload}, socket) do
    {:noreply, reload_messages(socket)}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Private helpers ---

  # Each image is charged against the member's upload buckets *before* it is
  # processed (`Messaging.create_dm_image/2`), so a refused upload costs no
  # decode and no disk (ADR 0071).
  defp handle_dm_image_progress(:dm_images, entry, socket) do
    if entry.done? do
      user = socket.assigns.current_user

      result =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          {:ok, Messaging.create_dm_image(user, path)}
        end)

      case result do
        {:ok, image} ->
          {:noreply,
           assign(socket, :uploaded_dm_images, socket.assigns.uploaded_dm_images ++ [image])}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, dm_image_refusal(reason))}
      end
    else
      {:noreply, socket}
    end
  end

  defp dm_image_refusal(:rate_limited),
    do: gettext("You have attached as many images as you can for now. Try again later.")

  defp dm_image_refusal(:too_many_pending),
    do: gettext("Send or remove the images you have attached before adding more.")

  defp dm_image_refusal(_),
    do: gettext("That file could not be used as an image.")

  # Mute and block state for a remote participant, shown in the header menu.
  defp assign_other_safety_state(socket) do
    case socket.assigns.other_participant do
      %Baudrate.Federation.RemoteActor{ap_id: ap_id} ->
        user = socket.assigns.current_user

        assign(socket,
          other_muted: Auth.muted?(user, ap_id),
          other_blocked: Auth.blocked?(user, ap_id)
        )

      _ ->
        assign(socket, other_muted: false, other_blocked: false)
    end
  end

  defp assign_messages(socket, messages) do
    has_older =
      case messages do
        [oldest | _] -> Messaging.messages_before?(socket.assigns.conversation, oldest.id)
        [] -> false
      end

    socket
    |> assign(:messages, messages)
    |> assign(:has_older_messages, has_older)
  end

  # Re-reads the newest messages, keeping as many as are already on the page
  # so a reload does not drop history the user loaded.
  defp reload_messages(socket) do
    limit = socket.assigns.messages |> length() |> max(@page_size) |> min(@max_loaded)
    assign_messages(socket, Messaging.list_messages(socket.assigns.conversation, limit: limit))
  end

  defp resolve_conversation(%{"id" => id}, user) do
    # A non-integer id used to reach Ecto and raise, so `/messages/abc` 500ed
    # rather than 404ing.
    conversation =
      case parse_id(id) do
        {:ok, conversation_id} -> Messaging.get_conversation_for_user(conversation_id, user)
        :error -> nil
      end

    case conversation do
      nil ->
        {:error, :not_found}

      conversation ->
        other = Messaging.other_participant(conversation, user)
        {:ok, conversation, other}
    end
  end

  defp resolve_conversation(%{"to" => username}, _user) do
    case Auth.get_user_by_username(username) do
      nil -> {:error, :recipient_not_found}
      %{status: "banned"} -> {:error, :recipient_not_found}
      recipient -> {:new, recipient}
    end
  end

  defp resolve_conversation(_params, _user), do: :select_recipient

  defp ensure_conversation(socket, user) do
    if socket.assigns.new_conversation do
      other = socket.assigns.other_participant
      {:ok, conversation} = Messaging.find_or_create_conversation(user, other)

      if connected?(socket) do
        MessagingPubSub.subscribe_conversation(conversation.id)
      end

      socket
      |> assign(:conversation, conversation)
      |> assign(:new_conversation, false)
    else
      socket
    end
  end

  defp mark_read(_conversation, _user, []), do: :ok

  defp mark_read(conversation, user, messages) when is_list(messages) do
    last = List.last(messages)
    if conversation && last, do: Messaging.mark_conversation_read(conversation, user, last)
  end

  defp send_refusal(:dm_images_local_only, _user),
    do:
      gettext(
        "Images can only be sent to members of this site, not to accounts on other servers."
      )

  # A new account is told what its limit is and when it lifts (ADR 0064);
  # anything else keeps the neutral refusal, which never says who blocked whom.
  defp send_refusal(reason, user),
    do:
      BaudrateWeb.Helpers.refusal_message(
        reason,
        user,
        gettext("You cannot send messages to this user.")
      )

  defp error_message(:not_found), do: gettext("Conversation not found.")
  defp error_message(:recipient_not_found), do: gettext("User not found.")
  defp error_message(_), do: gettext("Something went wrong.")
end
