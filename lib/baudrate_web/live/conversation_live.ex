defmodule BaudrateWeb.ConversationLive do
  @moduledoc """
  LiveView for a single conversation thread (`/messages/:id` or `/messages/new?to=username`).

  Displays messages as bubbles with sender alignment, supports sending new
  messages, deleting own messages, and auto-marks messages as read.
  Subscribes to conversation-level PubSub for real-time updates.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Auth
  alias Baudrate.Messaging
  alias Baudrate.Messaging.PubSub, as: MessagingPubSub
  import BaudrateWeb.Helpers, only: [parse_id: 1]

  @impl true
  def mount(params, _session, socket) do
    user = socket.assigns.current_user

    case resolve_conversation(params, user) do
      {:ok, conversation, other} ->
        mount_conversation(socket, user, conversation, other)

      {:new, recipient} ->
        mount_new_conversation(socket, user, recipient)

      {:error, reason} ->
        {:ok,
         socket
         |> put_flash(:error, error_message(reason))
         |> redirect(to: ~p"/messages")}
    end
  end

  defp mount_conversation(socket, user, conversation, other) do
    if connected?(socket) do
      MessagingPubSub.subscribe_conversation(conversation.id)
    end

    messages = Messaging.list_messages(conversation)
    mark_read(conversation, user, messages)

    socket =
      socket
      |> assign(:conversation, conversation)
      |> assign(:messages, messages)
      |> assign(:other_participant, other)
      |> assign(:new_conversation, false)
      |> assign(:page_title, participant_name(other))
      |> assign(:message_form, to_form(%{"body" => ""}, as: :message))

    {:ok, socket}
  end

  defp mount_new_conversation(socket, user, recipient) do
    if Messaging.can_send_dm?(user, recipient) do
      socket =
        socket
        |> assign(:conversation, nil)
        |> assign(:messages, [])
        |> assign(:other_participant, recipient)
        |> assign(:new_conversation, true)
        |> assign(:page_title, gettext("New Message"))
        |> assign(:message_form, to_form(%{"body" => ""}, as: :message))

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You cannot send messages to this user."))
       |> redirect(to: ~p"/messages")}
    end
  end

  @impl true
  def handle_event("send_message", %{"message" => %{"body" => body}}, socket) do
    user = socket.assigns.current_user
    body = String.trim(body)

    if body == "" do
      {:noreply, socket}
    else
      socket = ensure_conversation(socket, user)
      conversation = socket.assigns.conversation

      case check_rate_limit(user.id) do
        :ok ->
          case Messaging.create_message(conversation, user, %{body: body}) do
            {:ok, message} ->
              messages = socket.assigns.messages ++ [Messaging.get_message(message.id)]
              mark_read(conversation, user, messages)

              {:noreply,
               socket
               |> assign(:messages, messages)
               |> assign(:message_form, to_form(%{"body" => ""}, as: :message))}

            {:error, _changeset} ->
              {:noreply, put_flash(socket, :error, gettext("Failed to send message."))}
          end

        {:error, :rate_limited} ->
          {:noreply,
           put_flash(socket, :error, gettext("Too many messages. Please slow down."))}
      end
    end
  end

  def handle_event("delete_message", %{"id" => id}, socket) do
    case parse_id(id) do
      :error -> {:noreply, socket}
      {:ok, msg_id} -> do_delete_message(socket, msg_id)
    end
  end

  defp do_delete_message(socket, msg_id) do
    user = socket.assigns.current_user

    case Messaging.get_message(msg_id) do
      nil ->
        {:noreply, socket}

      message ->
        case Messaging.soft_delete_message(message, user) do
          {:ok, _} ->
            messages = Messaging.list_messages(socket.assigns.conversation)
            {:noreply, assign(socket, :messages, messages)}

          {:error, :unauthorized} ->
            {:noreply, put_flash(socket, :error, gettext("You can only delete your own messages."))}

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
      messages = socket.assigns.messages ++ [message]
      mark_read(socket.assigns.conversation, user, messages)
      {:noreply, assign(socket, :messages, messages)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:dm_message_deleted, _payload}, socket) do
    messages = Messaging.list_messages(socket.assigns.conversation)
    {:noreply, assign(socket, :messages, messages)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Private helpers ---

  defp resolve_conversation(%{"id" => id}, user) do
    case Messaging.get_conversation_for_user(id, user) do
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

  defp resolve_conversation(_params, _user), do: {:error, :invalid_params}

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

  defp error_message(:not_found), do: gettext("Conversation not found.")
  defp error_message(:recipient_not_found), do: gettext("User not found.")
  defp error_message(:invalid_params), do: gettext("Invalid request.")
  defp error_message(_), do: gettext("Something went wrong.")

  defp participant_name(%Baudrate.Setup.User{} = user), do: user.username

  defp participant_name(%Baudrate.Federation.RemoteActor{} = actor),
    do: "#{actor.username}@#{actor.domain}"

  defp participant_name(_), do: "?"

  defp check_rate_limit(user_id) do
    case Hammer.check_rate("dm:user:#{user_id}", 60_000, 20) do
      {:allow, _count} -> :ok
      {:deny, _limit} -> {:error, :rate_limited}
    end
  end
end
