defmodule BaudrateWeb.RegisterLive do
  @moduledoc """
  LiveView for public user registration.

  Registration is handled entirely within LiveView (no phx-trigger-action
  needed since there are no session writes). Rate limiting is enforced
  via Hammer at 5 registrations per hour per IP.

  The registration mode (`Setup.registration_mode/0`) determines:
    * `"open"` — account is immediately active
    * `"approval_required"` — account is pending admin approval
  """

  use BaudrateWeb, :live_view

  require Logger

  alias Baudrate.Auth
  alias Baudrate.Setup
  alias Baudrate.Setup.User

  @impl true
  def mount(_params, _session, socket) do
    changeset = User.registration_changeset(%User{}, %{})
    registration_mode = Setup.registration_mode()

    peer_ip =
      if connected?(socket) do
        case get_connect_info(socket, :peer_data) do
          %{address: addr} -> addr |> :inet.ntoa() |> to_string()
          _ -> "unknown"
        end
      else
        "unknown"
      end

    socket =
      socket
      |> assign(:form, to_form(changeset, as: :user))
      |> assign(:registration_mode, registration_mode)
      |> assign(:password_strength, password_strength(""))
      |> assign(:peer_ip, peer_ip)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    changeset =
      %User{}
      |> User.registration_changeset(params)
      |> Map.put(:action, :validate)

    password = params["password"] || ""

    {:noreply,
     socket
     |> assign(:form, to_form(changeset, as: :user))
     |> assign(:password_strength, password_strength(password))}
  end

  @impl true
  def handle_event("submit", %{"user" => params}, socket) do
    ip = socket.assigns.peer_ip

    case Hammer.check_rate("register:#{ip}", 3_600_000, 5) do
      {:deny, _limit} ->
        Logger.warning("rate_limit.denied: action=register ip=#{ip}")

        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Too many registration attempts. Please try again later.")
         )}

      _ ->
        do_register(socket, params)
    end
  end

  defp do_register(socket, params) do
    case Auth.register_user(params) do
      {:ok, _user} ->
        flash_msg =
          case socket.assigns.registration_mode do
            "open" ->
              gettext("Registration successful! You can now sign in.")

            "invite_only" ->
              gettext("Registration successful! You can now sign in.")

            _ ->
              gettext(
                "Your account has been created and is pending admin approval. You can sign in, but posting and avatar upload are restricted until approved."
              )
          end

        {:noreply,
         socket
         |> put_flash(:info, flash_msg)
         |> redirect(to: ~p"/login")}

      {:error, :invite_required} ->
        {:noreply,
         put_flash(socket, :error, gettext("An invite code is required to register."))}

      {:error, {:invalid_invite, :not_found}} ->
        {:noreply, put_flash(socket, :error, gettext("Invalid invite code."))}

      {:error, {:invalid_invite, :revoked}} ->
        {:noreply, put_flash(socket, :error, gettext("This invite code has been revoked."))}

      {:error, {:invalid_invite, :expired}} ->
        {:noreply, put_flash(socket, :error, gettext("This invite code has expired."))}

      {:error, {:invalid_invite, :fully_used}} ->
        {:noreply, put_flash(socket, :error, gettext("This invite code has already been used."))}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :user))}
    end
  end

  defp password_strength(password) do
    %{
      length: String.length(password) >= 12,
      lowercase: Regex.match?(~r/[a-z]/, password),
      uppercase: Regex.match?(~r/[A-Z]/, password),
      digit: Regex.match?(~r/[0-9]/, password),
      special: Regex.match?(~r/[^a-zA-Z0-9]/, password)
    }
  end
end
