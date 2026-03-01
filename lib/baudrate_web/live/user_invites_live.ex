defmodule BaudrateWeb.UserInvitesLive do
  @moduledoc """
  LiveView for user-facing invite code management.

  Allows authenticated users to generate invite codes (with quota limits)
  and manage their own codes. Admins have unlimited quota; regular users
  are limited to #{Baudrate.Auth.invite_quota_limit()} codes per rolling 30-day window.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Auth
  import BaudrateWeb.Helpers, only: [parse_id: 1, invite_url: 1]

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(page_title: gettext("My Invites"), qr_modal_code: nil)
     |> load_invite_data(user)}
  end

  @impl true
  def handle_event("generate", _params, socket) do
    user = socket.assigns.current_user

    case Auth.generate_invite_code(user) do
      {:ok, _code} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Invite code generated."))
         |> load_invite_data(user)}

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
  def handle_event("show_qr_code", %{"code" => code}, socket) do
    {:noreply, assign(socket, :qr_modal_code, code)}
  end

  @impl true
  def handle_event("close_qr_modal", _params, socket) do
    {:noreply, assign(socket, :qr_modal_code, nil)}
  end

  @impl true
  def handle_event("revoke", %{"id" => id}, socket) do
    case parse_id(id) do
      :error -> {:noreply, socket}
      {:ok, invite_id} -> do_revoke(socket, invite_id)
    end
  end

  defp do_revoke(socket, invite_id) do
    user = socket.assigns.current_user
    invite = Auth.get_invite_code(invite_id)

    cond do
      is_nil(invite) ->
        {:noreply, put_flash(socket, :error, gettext("Invite code not found."))}

      invite.created_by_id != user.id ->
        {:noreply,
         put_flash(socket, :error, gettext("You can only revoke your own invite codes."))}

      true ->
        case Auth.revoke_invite_code(invite) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Invite code revoked."))
             |> load_invite_data(user)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to revoke invite code."))}
        end
    end
  end

  defp load_invite_data(socket, user) do
    codes = Auth.list_user_invite_codes(user)
    remaining = Auth.invite_quota_remaining(user)
    limit = Auth.invite_quota_limit()
    can_generate = match?({:ok, _}, Auth.can_generate_invite?(user))

    assign(socket,
      codes: codes,
      quota_remaining: remaining,
      quota_limit: limit,
      can_generate: can_generate,
      qr_codes: build_qr_codes(codes)
    )
  end

  defp build_qr_codes(codes) do
    for code <- codes,
        code_status(code) == :active,
        into: %{} do
      {code.code, Auth.totp_qr_data_uri(invite_url(code.code))}
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
