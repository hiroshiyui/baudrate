defmodule BaudrateWeb.RegisterLive do
  @moduledoc """
  LiveView for public registration at `/register`.

  Honours all three registration modes (`open`, `approval_required`,
  `invite_only`); `Setup.registration_mode/0` decides which, and the mode only
  changes what the new account's status is and what the flash says.

  Registration shows the ten recovery codes **once**, and acknowledging them is
  what signs the member in (P4-D2). With no email in this system those codes
  are the only self-service way back into the account, so they come before the
  session rather than after it — a new member who closes the tab at the wrong
  moment has an account they cannot recover.

  The sign-in itself is the same `phx-trigger-action` POST to
  `SessionController.create/2` that `LoginLive` uses, so a role whose TOTP
  policy is `:required` still lands on `/totp/setup` rather than the home page.
  """

  use BaudrateWeb, :live_view

  require Logger

  alias Baudrate.Auth
  alias Baudrate.Setup
  alias Baudrate.Setup.User
  import BaudrateWeb.Helpers, only: [password_strength: 1, extract_peer_ip: 1]

  @impl true
  def mount(_params, _session, socket) do
    changeset = User.registration_changeset(%User{}, %{})
    registration_mode = Setup.registration_mode()
    eua = Setup.get_eua()

    peer_ip = if connected?(socket), do: extract_peer_ip(socket), else: "unknown"

    socket =
      socket
      |> assign(:form, to_form(changeset, as: :user))
      |> assign(:registration_mode, registration_mode)
      |> assign(:password_strength, password_strength(""))
      |> assign(:peer_ip, peer_ip)
      |> assign(:recovery_codes, nil)
      |> assign(:registered_user_id, nil)
      |> assign(:token, nil)
      |> assign(:trigger_action, false)
      |> assign(:eua, eua)
      |> assign(:page_title, gettext("Register"))
      |> assign(:invite_code_value, nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :invite_code_value, params["invite"])}
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
     |> assign(:password_strength, password_strength(password))
     |> assign(:invite_code_value, params["invite_code"])}
  end

  @impl true
  def handle_event("submit", %{"user" => params}, socket) do
    ip = socket.assigns.peer_ip

    case BaudrateWeb.RateLimiter.check_rate("register:#{ip}", 3_600_000, 5) do
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

  @impl true
  def handle_event("ack_codes", _params, socket) do
    # P4-D2: acknowledging the codes is what signs a new member in, so nobody
    # is carried past the only copy of them they will ever see — and nobody
    # types the password they just chose a second time.
    #
    # The token is minted *here* rather than at registration because it is
    # only good for 60 seconds and writing down ten codes takes longer than
    # that. The user id it names has sat in socket assigns since `do_register`
    # — server-side state, never anything the client supplied.
    case socket.assigns.registered_user_id do
      nil ->
        {:noreply, redirect(socket, to: ~p"/login")}

      user_id ->
        token = Phoenix.Token.sign(socket.endpoint, "user_auth", user_id)

        {:noreply,
         socket
         |> assign(:token, token)
         |> assign(:trigger_action, true)}
    end
  end

  defp do_register(socket, params) do
    case Auth.register_user(params) do
      {:ok, user, codes} ->
        flash_msg =
          if socket.assigns.registration_mode in ["open", "invite_only"] do
            gettext("Welcome! Save your recovery codes and you are in.")
          else
            gettext(
              "Your account has been created and is waiting for a moderator to approve it. You can look around and set up your profile in the meantime."
            )
          end

        {:noreply,
         socket
         |> put_flash(:info, flash_msg)
         |> assign(:recovery_codes, codes)
         |> assign(:registered_user_id, user.id)}

      {:error, :invite_required} ->
        {:noreply, put_flash(socket, :error, gettext("An invite code is required to register."))}

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
end
