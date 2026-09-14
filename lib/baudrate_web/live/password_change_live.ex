defmodule BaudrateWeb.PasswordChangeLive do
  @moduledoc """
  LiveView for changing the password while signed in (`/profile/password`).

  ## Flow

  1. The new password and confirmation are validated first
     (`Auth.password_change_changeset/2`: policy, confirmation, and different
     from the current password). Mistakes there do not use up a
     re-authentication attempt.
  2. Step-up re-authentication: the current password, plus the current TOTP
     code when TOTP is enabled, via `Auth.verify_reauthentication/5` behind
     `RateLimits.check_reauth/1` (ADR 0022). Recovery codes are not accepted.
  3. `Auth.change_password/3` stores the new hash, revokes every **other**
     session (closing their LiveView sockets) while keeping this one, and
     sends the always-delivered `password_changed` security notice.

  This gives a user who notices suspicious activity, such as an unexpected
  data export request (ADR 0023), a way to lock out an attacker who knows the
  old password without signing themselves out.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Auth
  alias BaudrateWeb.RateLimits

  import BaudrateWeb.Helpers, only: [password_strength: 1, extract_peer_ip: 1]

  @impl true
  def mount(_params, session, socket) do
    socket =
      socket
      |> assign(:form, empty_form())
      |> assign(:password_strength, password_strength(""))
      |> assign(:password_errors, [])
      |> assign(:confirmation_errors, [])
      |> assign(:peer_ip, if(connected?(socket), do: extract_peer_ip(socket), else: "unknown"))
      # The session row id, not the token: tokens rotate daily, the row id does not.
      |> assign(:session_id, Auth.session_id_by_token(session["session_token"]))
      |> assign(:page_title, gettext("Change Password"))

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"password_change" => params}, socket) do
    {:noreply, assign(socket, :password_strength, password_strength(params["password"] || ""))}
  end

  @impl true
  def handle_event("submit", %{"password_change" => params}, socket) do
    user = socket.assigns.current_user

    new_password_attrs = %{
      "password" => params["password"] || "",
      "password_confirmation" => params["password_confirmation"] || ""
    }

    validation = Auth.password_change_changeset(user, new_password_attrs)

    cond do
      not validation.valid? ->
        {:noreply,
         socket
         |> assign_errors(validation)
         |> put_flash(:error, gettext("Please fix the problems with the new password."))
         |> push_event("focus", %{id: "password_change_password"})}

      is_nil(socket.assigns.session_id) ->
        {:noreply,
         put_flash(socket, :error, gettext("Your session has expired. Please sign in again."))}

      true ->
        reauthenticate_and_change(socket, user, params, new_password_attrs)
    end
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp reauthenticate_and_change(socket, user, params, new_password_attrs) do
    result =
      with :ok <- RateLimits.check_reauth(user.id),
           :ok <-
             Auth.verify_reauthentication(
               user,
               params["current_password"],
               params["code"],
               socket.assigns.peer_ip,
               :password_change
             ) do
        Auth.change_password(user, new_password_attrs, socket.assigns.session_id)
      end

    case result do
      {:ok, _user, revoked} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           ngettext(
             "Password changed. %{count} other session was signed out.",
             "Password changed. %{count} other sessions were signed out.",
             revoked,
             count: revoked
           )
         )
         |> push_navigate(to: ~p"/profile")}

      {:error, :rate_limited} ->
        {:noreply,
         socket
         |> reset_form()
         |> put_flash(:error, gettext("Too many attempts. Please try again later."))}

      {:error, {:throttled, seconds}} ->
        {:noreply,
         socket
         |> reset_form()
         |> put_flash(
           :error,
           gettext("Too many failed attempts. Please try again in %{seconds} seconds.",
             seconds: seconds
           )
         )}

      {:error, :invalid_credentials} ->
        {:noreply,
         socket
         |> reset_form()
         |> put_flash(:error, gettext("Invalid credentials. Please try again."))
         |> push_event("focus", %{id: "password_change_current_password"})}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign_errors(changeset)
         |> put_flash(:error, gettext("Please fix the problems with the new password."))}
    end
  end

  defp assign_errors(socket, changeset) do
    socket
    |> assign(
      :password_errors,
      BaudrateWeb.CoreComponents.translate_errors(changeset.errors, :password)
    )
    |> assign(
      :confirmation_errors,
      BaudrateWeb.CoreComponents.translate_errors(changeset.errors, :password_confirmation)
    )
  end

  defp reset_form(socket) do
    socket
    |> assign(:form, empty_form())
    |> assign(:password_errors, [])
    |> assign(:confirmation_errors, [])
  end

  defp empty_form, do: to_form(%{}, as: :password_change)
end
