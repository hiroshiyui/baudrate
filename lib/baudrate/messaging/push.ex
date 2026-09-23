defmodule Baudrate.Messaging.Push do
  @moduledoc """
  Decides whether a new direct message is pushed to its recipient
  (6D, ADR 0071), and schedules it.

  A direct message makes **no row on `/notifications`**: it has its own
  unread badge on Messages, and a second list of the same messages would be
  one more thing to read and clear. The push is the only notice.

  Nothing is pushed when the recipient has muted or blocked the sender, has
  turned direct-message pushes off (the push-only `"direct_message"`
  preference), or has no push subscription. The payload names the sender
  and carries no text (`WebPush.deliver_direct_message/3`).

  Best-effort: scheduled like every other push (`:web_push_async`), so a
  push lost to a restart is not retried.
  """

  alias Baudrate.Auth
  alias Baudrate.Federation.RemoteActor
  alias Baudrate.Notification.WebPush
  alias Baudrate.Setup.User

  @doc "Pushes the arrival of a message from `sender` to `recipient_id`, if wanted."
  def notify(recipient_id, sender, conversation_id) do
    with %User{} = recipient <- Auth.get_user(recipient_id),
         true <- wanted?(recipient, sender) do
      schedule(fn -> WebPush.deliver_direct_message(recipient, sender, conversation_id) end)
    end

    :ok
  end

  @doc """
  Whether `recipient` wants a push about a message from `sender`: they have
  not switched direct-message pushes off, and have not muted or blocked the
  sender.
  """
  def wanted?(%User{} = recipient, sender) do
    prefs = recipient.notification_preferences || %{}

    get_in(prefs, ["direct_message", "web_push"]) != false and
      not hidden?(recipient, sender)
  end

  defp hidden?(recipient, sender) do
    {user_ids, ap_ids} = Auth.hidden_ids(recipient)

    case sender do
      %User{id: id} -> id in user_ids
      %RemoteActor{ap_id: ap_id} -> ap_id in ap_ids
      _ -> false
    end
  end

  defp schedule(fun) do
    if Application.get_env(:baudrate, :web_push_async, true) do
      Task.Supervisor.start_child(Baudrate.Federation.TaskSupervisor, fun)
    else
      fun.()
    end
  end
end
