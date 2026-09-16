defmodule BaudrateWeb.Admin.InstanceDetailLive do
  @moduledoc """
  One remote instance: whether it is blocked, and the actors we know on it.

  This is where a report about a single remote account gets an answer
  proportionate to it (ADR 0030, decision 6) — suspending one actor rather than
  blocking every account on its domain. Staff surfaces deliberately keep
  showing hidden content (decision 7): moderators cannot judge what they cannot
  see, and a block is often applied before the content has been reviewed.
  """

  use BaudrateWeb, :live_view

  on_mount {BaudrateWeb.AuthHooks, :require_admin}

  alias Baudrate.Federation.{DomainBlock, DomainBlocks, RemoteActors}
  alias Baudrate.Moderation
  import BaudrateWeb.Helpers, only: [parse_id: 1]

  @impl true
  def mount(%{"domain" => domain}, _session, socket) do
    domain = DomainBlock.normalize_domain(domain)

    {:ok,
     socket
     |> assign(domain: domain, suspending_id: nil, suspend_reason: "")
     |> assign(:page_title, gettext("Instance %{domain}", domain: domain))
     |> load_instance()}
  end

  @impl true
  def handle_event("start_suspend", %{"id" => id}, socket) do
    case parse_id(id) do
      :error ->
        {:noreply, socket}

      {:ok, actor_id} ->
        {:noreply,
         socket
         |> assign(suspending_id: actor_id, suspend_reason: "")
         |> push_event("focus", %{id: "suspend-reason-#{actor_id}"})}
    end
  end

  @impl true
  def handle_event("cancel_suspend", _params, socket) do
    {:noreply,
     socket
     |> assign(suspending_id: nil, suspend_reason: "")
     |> push_event("focus", %{id: "instance-actors-heading"})}
  end

  @impl true
  def handle_event("validate_suspend", %{"reason" => reason}, socket) do
    {:noreply, assign(socket, suspend_reason: reason)}
  end

  @impl true
  def handle_event("suspend_actor", %{"actor_id" => id, "reason" => reason}, socket) do
    reason = String.trim(reason)

    with {:ok, actor_id} <- parse_id(id),
         %{} = actor <- RemoteActors.get_remote_actor(actor_id),
         false <- reason == "",
         {:ok, suspended} <- RemoteActors.suspend(actor, socket.assigns.current_user, reason) do
      Moderation.log_action(socket.assigns.current_user.id, "suspend_remote_actor",
        details: %{actor: suspended.ap_id, domain: suspended.domain, reason: reason}
      )

      {:noreply,
       socket
       |> put_flash(
         :info,
         gettext("%{actor} is suspended. Its content is hidden.", actor: handle(suspended))
       )
       |> assign(suspending_id: nil, suspend_reason: "")
       |> load_instance()
       |> push_event("focus", %{id: "instance-actors-heading"})}
    else
      true ->
        {:noreply, put_flash(socket, :error, gettext("Say why this account is suspended."))}

      _ ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("That account could not be suspended."))
         |> assign(suspending_id: nil, suspend_reason: "")
         |> load_instance()}
    end
  end

  @impl true
  def handle_event("unsuspend_actor", %{"id" => id}, socket) do
    with {:ok, actor_id} <- parse_id(id),
         %{} = actor <- RemoteActors.get_remote_actor(actor_id),
         {:ok, lifted} <- RemoteActors.unsuspend(actor) do
      Moderation.log_action(socket.assigns.current_user.id, "unsuspend_remote_actor",
        details: %{actor: lifted.ap_id, domain: lifted.domain}
      )

      {:noreply,
       socket
       |> put_flash(
         :info,
         gettext("%{actor} is no longer suspended.", actor: handle(lifted))
       )
       |> load_instance()
       |> push_event("focus", %{id: "instance-actors-heading"})}
    else
      _ ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("That account is not suspended."))
         |> load_instance()}
    end
  end

  @doc """
  Renders `@username@domain`, the way the rest of the UI names a remote actor.
  """
  def handle(actor), do: "@#{actor.username}@#{actor.domain}"

  defp load_instance(socket) do
    domain = socket.assigns.domain

    assign(socket,
      actors: RemoteActors.list_actors_for_domain(domain),
      domain_block: DomainBlocks.get_domain_block(domain)
    )
  end
end
