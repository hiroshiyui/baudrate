defmodule BaudrateWeb.ProfilePrivacyLive do
  @moduledoc """
  LiveView for a member's privacy settings (`/profile/privacy`): who may send
  them direct messages, and the accounts they have blocked or muted.

  ## Blocked and Muted Accounts

  The Blocked Accounts and Muted Users sections list local users and remote
  actors, each with an undo control. Remote actors are stored by AP ID and
  shown as `@user@domain` when the actor is known (`@safety_remote_actors`).
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Auth

  import BaudrateWeb.ProfileComponents

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign_blocks_and_mutes(socket.assigns.current_user)
      |> assign(:page_title, gettext("Privacy"))

    {:ok, socket}
  end

  @impl true
  def handle_event("unmute", %{"id" => id}, socket) do
    user = socket.assigns.current_user
    mute = Enum.find(socket.assigns.mutes, &(to_string(&1.id) == id))

    if mute do
      if mute.muted_user_id do
        muted_user = Auth.get_user(mute.muted_user_id)
        if muted_user, do: Auth.unmute_user(user, muted_user)
      else
        Auth.unmute_remote_actor(user, mute.muted_actor_ap_id)
      end

      {:noreply,
       socket
       |> assign_blocks_and_mutes(user)
       |> put_flash(:info, gettext("User unmuted."))
       |> push_event("focus", %{id: "profile-muted-users-heading"})}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("unblock", %{"id" => id}, socket) do
    user = socket.assigns.current_user
    block = Enum.find(socket.assigns.blocks, &(to_string(&1.id) == id))

    if block do
      if block.blocked_user_id do
        blocked_user = Auth.get_user(block.blocked_user_id)
        if blocked_user, do: Auth.unblock_user(user, blocked_user)
      else
        Auth.unblock_remote_actor(user, block.blocked_actor_ap_id)
      end

      {:noreply,
       socket
       |> assign_blocks_and_mutes(user)
       |> put_flash(:info, gettext("Account unblocked."))
       |> push_event("focus", %{id: "profile-blocked-accounts-heading"})}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("update_dm_access", %{"dm_access" => value}, socket) do
    user = socket.assigns.current_user

    case Auth.update_dm_access(user, value) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(:current_user, updated_user)
         |> put_flash(:info, gettext("DM access setting updated."))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update DM access setting."))}
    end
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # Blocks and mutes of remote actors are stored by AP ID; the known actors are
  # looked up so the lists can show `@user@domain` instead of a bare URI.
  defp assign_blocks_and_mutes(socket, user) do
    blocks = Auth.list_blocks(user)
    mutes = Auth.list_mutes(user)

    remote_actors =
      (Enum.map(blocks, & &1.blocked_actor_ap_id) ++ Enum.map(mutes, & &1.muted_actor_ap_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Baudrate.Federation.remote_actors_by_ap_ids()

    assign(socket, blocks: blocks, mutes: mutes, safety_remote_actors: remote_actors)
  end

  attr :user, :any, default: nil
  attr :ap_id, :string, default: nil
  attr :remote_actors, :map, required: true
  attr :name_class, :string, required: true

  # One account in the blocked or muted list: a local user, a known remote
  # actor, or (for an actor this instance no longer knows) its AP ID.
  defp safety_list_account(assigns) do
    assigns =
      assign(assigns, :remote_actor, assigns.ap_id && assigns.remote_actors[assigns.ap_id])

    ~H"""
    <%= cond do %>
      <% @user -> %>
        <.avatar user={@user} size={36} />
        <span class={[@name_class, "font-semibold break-words min-w-0"]}>
          {display_name(@user)}
          <span class="text-sm font-normal text-base-content/70">@{@user.username}</span>
        </span>
      <% @remote_actor -> %>
        <div class="avatar avatar-placeholder">
          <div
            class="bg-neutral text-neutral-content rounded-full"
            style="width: 36px; height: 36px"
          >
            <span class="text-xs">@</span>
          </div>
        </div>
        <span class={[@name_class, "font-semibold break-words min-w-0"]}>
          {display_name(@remote_actor)}
          <span class="text-sm font-normal text-base-content/70 break-all">
            @{@remote_actor.username}@{@remote_actor.domain}
          </span>
        </span>
      <% true -> %>
        <div class="avatar avatar-placeholder">
          <div
            class="bg-neutral text-neutral-content rounded-full"
            style="width: 36px; height: 36px"
          >
            <span class="text-xs">@</span>
          </div>
        </div>
        <span class={[@name_class, "text-sm text-base-content/70 break-all min-w-0"]}>{@ap_id}</span>
    <% end %>
    """
  end

  defp safety_list_name(%Baudrate.Setup.User{username: username}, _ap_id, _actors), do: username

  defp safety_list_name(_user, ap_id, actors) do
    case actors[ap_id] do
      %{username: username, domain: domain} -> "@#{username}@#{domain}"
      nil -> ap_id
    end
  end
end
