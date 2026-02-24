defmodule BaudrateWeb.Admin.InvitesLive do
  @moduledoc """
  LiveView for admin invite code management.

  Only accessible to users with the `"admin"` role. Provides
  generation and revocation of invite codes, and shows invite chain
  information (which users were created from each code).
  """

  use BaudrateWeb, :live_view

  on_mount {BaudrateWeb.AuthHooks, :require_admin}

  alias Baudrate.Auth
  import BaudrateWeb.Helpers, only: [parse_id: 1]

  @impl true
  def mount(_params, _session, socket) do
    codes = Auth.list_all_invite_codes()

    {:ok,
     assign(socket,
       codes: codes,
       wide_layout: true,
       page_title: gettext("Admin Invites")
     )}
  end

  @impl true
  def handle_event("generate", _params, socket) do
    case Auth.generate_invite_code(socket.assigns.current_user) do
      {:ok, _code} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Invite code generated."))
         |> assign(:codes, Auth.list_all_invite_codes())}

      {:error, :account_too_new} ->
        {:noreply,
         put_flash(socket, :error, gettext("Your account is too new to generate invite codes."))}

      {:error, :invite_quota_exceeded} ->
        {:noreply, put_flash(socket, :error, gettext("Invite quota exceeded."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to generate invite code."))}
    end
  end

  @impl true
  def handle_event("revoke", %{"id" => id}, socket) do
    case parse_id(id) do
      :error -> {:noreply, socket}
      {:ok, invite_id} -> do_revoke(socket, invite_id)
    end
  end

  defp do_revoke(socket, invite_id) do
    invite = Baudrate.Repo.get!(Auth.InviteCode, invite_id)

    case Auth.revoke_invite_code(invite) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Invite code revoked."))
         |> assign(:codes, Auth.list_all_invite_codes())}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to revoke invite code."))}
    end
  end

  defp code_status(invite) do
    cond do
      invite.revoked ->
        :revoked

      invite.expires_at && DateTime.compare(invite.expires_at, DateTime.utc_now()) == :lt ->
        :expired

      invite.use_count >= invite.max_uses ->
        :used

      true ->
        :active
    end
  end
end
