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
  alias Baudrate.Auth.Challenge
  alias Baudrate.Setup
  alias Baudrate.Setup.User
  import BaudrateWeb.Helpers, only: [password_strength: 1, extract_peer_ip: 1]

  @impl true
  def mount(_params, _session, socket) do
    changeset = User.registration_changeset(%User{}, %{})
    registration_mode = Setup.registration_mode()
    eua = Setup.get_eua()

    peer_ip = if connected?(socket), do: extract_peer_ip(socket), else: "unknown"

    # Both are decided only once the socket is up: the dead render has no
    # trustworthy peer address, and a challenge issued there would be
    # discarded with the process that issued it.
    connected = connected?(socket)

    socket =
      socket
      |> assign(:ip_banned, connected and Auth.ip_banned?(peer_ip))
      |> assign(:challenge, if(connected, do: Challenge.issue()))
      |> assign(:challenge_solution, nil)
      |> assign(:pending_submit, nil)
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

    # Checked again on submit, not only at mount: a ban can be issued while the
    # page is open, and the mount-time value only decides what is rendered.
    if Auth.ip_banned?(ip) do
      Logger.warning("auth.ip_banned: step=register ip=#{ip}")

      {:noreply,
       socket
       |> assign(:ip_banned, true)
       |> put_flash(:error, BaudrateWeb.Helpers.ip_banned_message())}
    else
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
          submit_when_solved(socket, params)
      end
    end
  end

  # The browser answers the challenge (P5-D1). An answer to a challenge that is
  # no longer current, or a wrong one, is ignored without a word: a legitimate
  # hook never sends either, and anything else does not deserve an explanation.
  def handle_event("challenge_solved", %{"nonce" => nonce, "solution" => solution}, socket) do
    challenge = socket.assigns.challenge

    if challenge && challenge.nonce == nonce && Challenge.solved?(challenge, solution) do
      socket = assign(socket, :challenge_solution, solution)

      case socket.assigns.pending_submit do
        nil -> {:noreply, socket}
        params -> do_register(assign(socket, :pending_submit, nil), params)
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("challenge_solved", _params, socket), do: {:noreply, socket}

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

  # A submit that arrives before the browser has answered is held, not
  # refused: the answer is usually a second away, and asking the visitor to
  # press the button again would read as the page not working. The status line
  # says what is happening while it waits.
  defp submit_when_solved(socket, params) do
    if Challenge.solved?(socket.assigns.challenge, socket.assigns.challenge_solution) do
      do_register(socket, params)
    else
      {:noreply, assign(socket, :pending_submit, params)}
    end
  end

  # One solve buys one attempt. Re-issued after *every* attempt, success
  # included: a consumed challenge left as `nil` would read as "switched off",
  # and a crafted socket could then register again and again on one solve.
  defp reissue_challenge(socket) do
    challenge = Challenge.issue()

    socket
    |> assign(:challenge, challenge)
    |> assign(:challenge_solution, nil)
    |> then(fn s ->
      if challenge,
        do: push_event(s, "challenge", %{nonce: challenge.nonce, bits: challenge.bits}),
        else: s
    end)
  end

  defp do_register(socket, params) do
    socket = reissue_challenge(socket)

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
