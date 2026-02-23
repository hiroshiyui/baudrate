defmodule Baudrate.Messaging do
  @moduledoc """
  The Messaging context handles 1-on-1 direct messages between users,
  including federated conversations with remote actors via ActivityPub.

  ## Conversations

  Each conversation is between exactly two participants (local-local or
  local-remote). Local-local conversations use canonical ordering
  (lower user_id = `user_a`) to prevent duplicates.

  ## DM Access Control

  Users can set `dm_access` to control who can message them:

    * `"anyone"` — any authenticated user can send a DM
    * `"followers"` — only AP followers can send DMs
    * `"nobody"` — DMs are disabled entirely

  Bidirectional blocks (via `Auth.blocked?/2`) are always enforced.

  ## Federation

  Local DMs to remote actors are published as `Create(Note)` activities
  with restricted addressing (recipient in `to`, no public/followers).
  Incoming DMs are received via the inbox handler and routed here.

  ## Real-time Updates

  PubSub notifications are broadcast after mutations. Only IDs are
  broadcast — subscribers re-fetch from the database.
  """

  import Ecto.Query

  alias Baudrate.Auth
  alias Baudrate.Content.Markdown
  alias Baudrate.Federation
  alias Baudrate.Messaging.{Conversation, ConversationReadCursor, DirectMessage, PubSub}
  alias Baudrate.Repo
  alias Baudrate.Setup.User

  # --- Access Control ---

  @doc """
  Returns `true` if `sender` is allowed to send a DM to `recipient`.

  Checks:
    1. Cannot message yourself
    2. Sender must be active
    3. Bidirectional block check
    4. Recipient's `dm_access` setting
  """
  def can_send_dm?(%User{id: id}, %User{id: id}), do: false

  def can_send_dm?(%User{} = sender, %User{} = recipient) do
    sender.status == "active" &&
      recipient.status == "active" &&
      !Auth.blocked?(sender, recipient) &&
      !Auth.blocked?(recipient, sender) &&
      dm_access_allows?(recipient, sender)
  end

  def can_send_dm?(_, _), do: false

  defp dm_access_allows?(%User{dm_access: "anyone"}, _sender), do: true
  defp dm_access_allows?(%User{dm_access: "nobody"}, _sender), do: false

  defp dm_access_allows?(%User{dm_access: "followers"} = recipient, sender) do
    actor_uri = Federation.actor_uri(:user, recipient.username)
    sender_uri = Federation.actor_uri(:user, sender.username)
    Federation.follower_exists?(actor_uri, sender_uri)
  end

  @doc """
  Returns `true` if a remote actor can send a DM to a local user.

  Checks: dm_access setting, domain block, user block on remote actor's AP ID.
  """
  def can_receive_remote_dm?(%User{} = local_user, remote_actor) do
    local_user.status == "active" &&
      local_user.dm_access != "nobody" &&
      !Federation.Validator.domain_blocked?(remote_actor.domain) &&
      !Auth.blocked?(local_user, remote_actor.ap_id) &&
      remote_dm_access_allows?(local_user, remote_actor)
  end

  defp remote_dm_access_allows?(%User{dm_access: "anyone"}, _remote_actor), do: true

  defp remote_dm_access_allows?(%User{dm_access: "followers"} = user, remote_actor) do
    actor_uri = Federation.actor_uri(:user, user.username)
    Federation.follower_exists?(actor_uri, remote_actor.ap_id)
  end

  defp remote_dm_access_allows?(_, _), do: false

  # --- Conversations ---

  @doc """
  Finds or creates a conversation between two local users.

  Uses canonical ordering (lower user_id = user_a) to prevent duplicate
  conversations. Returns `{:ok, conversation}`.
  """
  def find_or_create_conversation(%User{id: id_a} = _user_a, %User{id: id_b} = _user_b) do
    {a_id, b_id} = if id_a < id_b, do: {id_a, id_b}, else: {id_b, id_a}

    case Repo.one(
           from(c in Conversation,
             where: c.user_a_id == ^a_id and c.user_b_id == ^b_id
           )
         ) do
      %Conversation{} = conv ->
        {:ok, conv}

      nil ->
        ap_context = generate_ap_context()

        %Conversation{}
        |> Conversation.local_changeset(%{
          user_a_id: a_id,
          user_b_id: b_id,
          ap_context: ap_context
        })
        |> Repo.insert()
    end
  end

  @doc """
  Finds or creates a conversation between a local user and a remote actor.

  The local user is always `user_a`, the remote actor is `remote_actor_b`.
  Returns `{:ok, conversation}`.
  """
  def find_or_create_remote_conversation(%User{id: user_id}, remote_actor) do
    case Repo.one(
           from(c in Conversation,
             where: c.user_a_id == ^user_id and c.remote_actor_b_id == ^remote_actor.id
           )
         ) do
      %Conversation{} = conv ->
        {:ok, conv}

      nil ->
        ap_context = generate_ap_context()

        %Conversation{}
        |> Conversation.remote_changeset(%{
          user_a_id: user_id,
          remote_actor_b_id: remote_actor.id,
          ap_context: ap_context
        })
        |> Repo.insert()
    end
  end

  @doc """
  Lists conversations for a user, ordered by most recent message first.

  Preloads the other participant and computes unread status.
  """
  def list_conversations(%User{id: user_id}, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(c in Conversation,
      where: c.user_a_id == ^user_id or c.user_b_id == ^user_id,
      where: not is_nil(c.last_message_at),
      order_by: [desc: c.last_message_at],
      limit: ^limit,
      preload: [:user_a, :user_b, :remote_actor_a, :remote_actor_b]
    )
    |> Repo.all()
  end

  @doc """
  Returns the total unread message count across all conversations for a user.
  """
  def unread_count(%User{id: user_id}) do
    # Count messages in all user's conversations that are newer than the read cursor
    from(dm in DirectMessage,
      join: c in Conversation,
      on: dm.conversation_id == c.id,
      where: (c.user_a_id == ^user_id or c.user_b_id == ^user_id),
      where: dm.sender_user_id != ^user_id or not is_nil(dm.sender_remote_actor_id),
      where: is_nil(dm.deleted_at),
      left_join: cursor in ConversationReadCursor,
      on: cursor.conversation_id == c.id and cursor.user_id == ^user_id,
      where:
        is_nil(cursor.id) or
          dm.id > cursor.last_read_message_id,
      select: count(dm.id)
    )
    |> Repo.one()
  end

  @doc """
  Returns the unread message count for a specific conversation.
  """
  def unread_count_for_conversation(conversation_id, %User{id: user_id}) do
    from(dm in DirectMessage,
      where: dm.conversation_id == ^conversation_id,
      where: dm.sender_user_id != ^user_id or not is_nil(dm.sender_remote_actor_id),
      where: is_nil(dm.deleted_at),
      left_join: cursor in ConversationReadCursor,
      on: cursor.conversation_id == ^conversation_id and cursor.user_id == ^user_id,
      where:
        is_nil(cursor.id) or
          dm.id > cursor.last_read_message_id,
      select: count(dm.id)
    )
    |> Repo.one()
  end

  # --- Messages ---

  @doc """
  Creates a new message in a conversation from a local user.

  Renders markdown to HTML, inserts the message, updates `last_message_at`,
  broadcasts PubSub events, and schedules federation delivery if the other
  participant is a remote actor.
  """
  def create_message(%Conversation{} = conversation, %User{} = sender, attrs) do
    body = attrs[:body] || attrs["body"] || ""
    body_html = Markdown.to_html(body)

    changeset =
      %DirectMessage{}
      |> DirectMessage.changeset(%{
        body: body,
        body_html: body_html,
        conversation_id: conversation.id,
        sender_user_id: sender.id
      })

    case Repo.insert(changeset) do
      {:ok, message} ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        conversation
        |> Ecto.Changeset.change(last_message_at: now)
        |> Repo.update()

        # Broadcast to both conversation and user topics
        PubSub.broadcast_to_conversation(conversation.id, :dm_message_created, %{
          message_id: message.id
        })

        other_user_id = other_local_user_id(conversation, sender.id)

        if other_user_id do
          PubSub.broadcast_to_user(other_user_id, :dm_received, %{
            conversation_id: conversation.id
          })
        end

        # Schedule federation delivery if other participant is remote
        maybe_federate_dm(message, conversation, sender)

        {:ok, message}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Receives a DM from a remote actor and stores it locally.

  Called by the inbox handler after validation and sanitization.
  Returns `{:ok, message}` or `{:error, reason}`.
  """
  def receive_remote_dm(%User{} = local_user, remote_actor, attrs) do
    {:ok, conversation} = find_or_create_remote_conversation(local_user, remote_actor)

    changeset =
      %DirectMessage{}
      |> DirectMessage.remote_changeset(%{
        body: attrs[:body] || attrs["body"],
        body_html: attrs[:body_html] || attrs["body_html"],
        conversation_id: conversation.id,
        sender_remote_actor_id: remote_actor.id,
        ap_id: attrs[:ap_id] || attrs["ap_id"],
        ap_in_reply_to: attrs[:ap_in_reply_to] || attrs["ap_in_reply_to"]
      })

    case Repo.insert(changeset) do
      {:ok, message} ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        conversation
        |> Ecto.Changeset.change(last_message_at: now)
        |> Repo.update()

        PubSub.broadcast_to_conversation(conversation.id, :dm_message_created, %{
          message_id: message.id
        })

        PubSub.broadcast_to_user(local_user.id, :dm_received, %{
          conversation_id: conversation.id
        })

        {:ok, message}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Lists messages in a conversation, paginated, oldest first.

  Excludes soft-deleted messages. Preloads sender_user and sender_remote_actor.
  """
  def list_messages(%Conversation{id: conversation_id}, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    after_id = Keyword.get(opts, :after_id)

    query =
      from(dm in DirectMessage,
        where: dm.conversation_id == ^conversation_id,
        where: is_nil(dm.deleted_at),
        order_by: [asc: dm.inserted_at],
        limit: ^limit,
        preload: [:sender_user, :sender_remote_actor]
      )

    query =
      if after_id do
        from(dm in query, where: dm.id > ^after_id)
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Soft-deletes a message. Only the sender can delete their own message.

  Schedules a Delete activity for remote participants.
  """
  def soft_delete_message(%DirectMessage{} = message, %User{id: user_id}) do
    if message.sender_user_id == user_id do
      result =
        message
        |> DirectMessage.soft_delete_changeset()
        |> Repo.update()

      with {:ok, deleted_message} <- result do
        PubSub.broadcast_to_conversation(message.conversation_id, :dm_message_deleted, %{
          message_id: message.id
        })

        conversation = Repo.get!(Conversation, message.conversation_id)
        maybe_federate_dm_delete(deleted_message, conversation, user_id)

        {:ok, deleted_message}
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Marks a conversation as read up to the given message for the user.

  Upserts the read cursor using ON CONFLICT.
  """
  def mark_conversation_read(%Conversation{id: conversation_id}, %User{id: user_id}, %DirectMessage{} = message) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %ConversationReadCursor{}
    |> ConversationReadCursor.changeset(%{
      conversation_id: conversation_id,
      user_id: user_id,
      last_read_message_id: message.id,
      last_read_at: now
    })
    |> Repo.insert(
      on_conflict: [
        set: [last_read_message_id: message.id, last_read_at: now, updated_at: now]
      ],
      conflict_target: [:conversation_id, :user_id]
    )
  end

  @doc """
  Returns the other participant in a conversation relative to the given user.

  Returns `%User{}` or `%RemoteActor{}` or `nil`.
  """
  def other_participant(%Conversation{} = conv, %User{id: user_id}) do
    conv = Repo.preload(conv, [:user_a, :user_b, :remote_actor_a, :remote_actor_b])

    cond do
      conv.user_a_id == user_id -> conv.user_b || conv.remote_actor_b
      conv.user_b_id == user_id -> conv.user_a || conv.remote_actor_a
      true -> nil
    end
  end

  @doc """
  Gets a conversation by ID, returning nil if not found.
  """
  def get_conversation(id) do
    Repo.get(Conversation, id)
  end

  @doc """
  Gets a conversation by ID, only if the user is a participant.

  Returns the conversation or nil.
  """
  def get_conversation_for_user(id, %User{id: user_id}) do
    Repo.one(
      from(c in Conversation,
        where: c.id == ^id,
        where: c.user_a_id == ^user_id or c.user_b_id == ^user_id
      )
    )
  end

  @doc """
  Gets a message by ID with preloads.
  """
  def get_message(id) do
    Repo.one(
      from(dm in DirectMessage,
        where: dm.id == ^id,
        preload: [:sender_user, :sender_remote_actor]
      )
    )
  end

  @doc """
  Gets a message by its AP ID, for federation idempotency checks.
  """
  def get_message_by_ap_id(ap_id) when is_binary(ap_id) do
    Repo.one(from(dm in DirectMessage, where: dm.ap_id == ^ap_id))
  end

  def get_message_by_ap_id(_), do: nil

  @doc """
  Returns a changeset for the message form.
  """
  def change_message(attrs \\ %{}) do
    DirectMessage.changeset(%DirectMessage{}, attrs)
  end

  @doc """
  Returns true if the user is a participant in the conversation.
  """
  def participant?(%Conversation{} = conv, %User{id: user_id}) do
    conv.user_a_id == user_id || conv.user_b_id == user_id
  end

  # --- Private Helpers ---

  defp other_local_user_id(%Conversation{user_a_id: a_id, user_b_id: b_id}, sender_id) do
    cond do
      a_id == sender_id -> b_id
      b_id == sender_id -> a_id
      true -> nil
    end
  end

  defp generate_ap_context do
    base = Federation.base_url()
    "#{base}/contexts/dm-#{System.unique_integer([:positive])}"
  end

  defp maybe_federate_dm(message, conversation, sender) do
    conversation = Repo.preload(conversation, [:remote_actor_b])

    if conversation.remote_actor_b do
      schedule_federation_task(fn ->
        Federation.Publisher.publish_dm_created(message, conversation, sender)
      end)
    end
  end

  defp maybe_federate_dm_delete(message, conversation, sender_user_id) do
    conversation = Repo.preload(conversation, [:remote_actor_b])

    if conversation.remote_actor_b do
      sender = Auth.get_user(sender_user_id)

      schedule_federation_task(fn ->
        Federation.Publisher.publish_dm_deleted(message, sender, conversation)
      end)
    end
  end

  defp schedule_federation_task(fun) do
    if Application.get_env(:baudrate, :federation_async, true) do
      Task.Supervisor.start_child(Baudrate.Federation.TaskSupervisor, fun)
    else
      fun.()
    end
  end
end
