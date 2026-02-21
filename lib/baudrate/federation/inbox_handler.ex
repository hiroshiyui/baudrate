defmodule Baudrate.Federation.InboxHandler do
  @moduledoc """
  Dispatches incoming ActivityPub activities to appropriate handlers.

  Supported activity types:
    * `Follow` — auto-accept, create follower record, send Accept(Follow)
    * `Undo` containing `Follow` — remove follower record
    * `Update` of actor — refresh cached RemoteActor
    * `Delete` of actor — remove all their follower records
    * Others — accept gracefully (202) but discard
  """

  require Logger

  alias Baudrate.Federation
  alias Baudrate.Federation.{ActorResolver, Delivery, Validator}

  @doc """
  Handles an incoming activity from a verified remote actor.
  Returns `:ok` or `{:error, reason}`.
  """
  def handle(activity, remote_actor, target) do
    with {:ok, activity} <- Validator.validate_activity(activity),
         :ok <- validate_domain(remote_actor),
         :ok <- validate_not_local(activity) do
      dispatch(activity, remote_actor, target)
    end
  end

  # --- Follow ---

  defp dispatch(%{"type" => "Follow"} = activity, remote_actor, target) do
    actor_uri = resolve_target_uri(activity, target)

    if actor_uri do
      case Federation.create_follower(actor_uri, remote_actor, activity["id"]) do
        {:ok, _follower} ->
          send_accept_async(activity, actor_uri, remote_actor)
          :ok

        {:error, %Ecto.Changeset{} = changeset} ->
          if has_unique_error?(changeset) do
            # Already following — still send Accept for idempotency
            send_accept_async(activity, actor_uri, remote_actor)
            :ok
          else
            {:error, :follow_failed}
          end
      end
    else
      {:error, :not_found}
    end
  end

  # --- Undo(Follow) ---

  defp dispatch(
         %{"type" => "Undo", "object" => %{"type" => "Follow"} = follow},
         remote_actor,
         _target
       ) do
    actor_uri = follow["object"]

    if is_binary(actor_uri) do
      Federation.delete_follower(actor_uri, remote_actor.ap_id)
      :ok
    else
      {:error, :invalid_undo}
    end
  end

  # --- Update(Person/Group/etc) ---

  defp dispatch(%{"type" => "Update", "actor" => actor_uri}, _remote_actor, _target) do
    Logger.info("federation.activity: type=Update actor=#{actor_uri}")
    ActorResolver.refresh(actor_uri)
    :ok
  end

  # --- Delete (actor deletion) ---

  defp dispatch(
         %{"type" => "Delete", "actor" => actor_uri, "object" => object},
         _remote_actor,
         _target
       )
       when object == actor_uri do
    Logger.info("federation.activity: type=Delete(actor) actor=#{actor_uri}")
    Federation.delete_followers_by_remote(actor_uri)
    :ok
  end

  # --- Deferred types: accept gracefully but discard ---

  defp dispatch(%{"type" => type} = _activity, _remote_actor, _target) do
    Logger.info("federation.activity_deferred: type=#{type}")
    :ok
  end

  # --- Helpers ---

  defp resolve_target_uri(%{"object" => object}, target) when is_binary(object) do
    # The object of a Follow is the actor being followed
    case target do
      {:user, user} ->
        uri = Federation.actor_uri(:user, user.username)
        if uri == object, do: uri, else: nil

      {:board, board} ->
        uri = Federation.actor_uri(:board, board.slug)
        if uri == object, do: uri, else: nil

      :shared ->
        # For shared inbox, accept if the object matches any local actor
        if Validator.local_actor?(object), do: object, else: nil
    end
  end

  defp resolve_target_uri(_, _), do: nil

  defp send_accept_async(follow_activity, actor_uri, remote_actor) do
    Task.Supervisor.start_child(
      Baudrate.Federation.TaskSupervisor,
      fn ->
        case Delivery.send_accept(follow_activity, actor_uri, remote_actor) do
          {:ok, _} ->
            Logger.info("federation.accept_sent: to=#{remote_actor.inbox}")

          {:error, reason} ->
            Logger.warning(
              "federation.accept_failed: to=#{remote_actor.inbox} reason=#{inspect(reason)}"
            )
        end
      end
    )
  end

  defp validate_domain(remote_actor) do
    if Validator.domain_blocked?(remote_actor.domain) do
      {:error, :domain_blocked}
    else
      :ok
    end
  end

  defp validate_not_local(%{"actor" => actor}) do
    if Validator.local_actor?(actor) do
      {:error, :self_referencing}
    else
      :ok
    end
  end

  defp has_unique_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_msg, opts}} ->
      Keyword.get(opts, :constraint) == :unique
    end)
  end
end
