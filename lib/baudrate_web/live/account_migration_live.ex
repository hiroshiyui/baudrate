defmodule BaudrateWeb.AccountMigrationLive do
  @moduledoc """
  LiveView for account migration (`/profile/move`, ADR 0025).

  ## Aliases

  An alias tells other servers that an account elsewhere belongs to the same
  person. It is needed in both directions: to move an account from another
  server to this one, list the old account here; to move this account away,
  the destination must list this account.

  Changing aliases needs step-up re-authentication (ADR 0022). A successful
  check unlocks alias management for `@reauth_seconds` seconds in this
  LiveView process only; every handler re-checks the deadline server-side, and
  a reload locks it again. Lookups run in `start_async/3` because they make
  outbound WebFinger and actor requests, and are limited by
  `RateLimits.check_account_alias/1`.

  ## Moving this account

  The request form takes the destination, the password and the current TOTP
  code. `AccountMigration.request_move/4` checks eligibility, verifies that the
  destination lists this account as an alias, and re-authenticates, inside the
  context. It runs in `start_async/3` because verifying the destination makes
  outbound requests. A pending move can be cancelled from any session, and
  the site-wide banner (`:active_account_move`) is refreshed on every change.

  Authorization and validation live in `Baudrate.AccountMigration`.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.{AccountMigration, Auth}
  alias BaudrateWeb.{DataExportLive, RateLimits}

  import BaudrateWeb.Helpers, only: [extract_peer_ip: 1]

  @reauth_seconds 300

  @impl true
  def mount(_params, session, socket) do
    user = socket.assigns.current_user
    user_agent = if connected?(socket), do: get_connect_info(socket, :user_agent), else: nil

    {:ok,
     socket
     |> assign(:page_title, gettext("Account Migration"))
     |> assign(:peer_ip, if(connected?(socket), do: extract_peer_ip(socket), else: "unknown"))
     |> assign(:user_agent, user_agent)
     |> assign(:session_id, Auth.session_id_by_token(session["session_token"]))
     |> assign(:reauth_until, nil)
     |> assign(:reauth_form, empty_reauth_form())
     |> assign(:alias_form, empty_alias_form())
     |> assign(:alias_lookup, false)
     |> assign(:move_form, empty_move_form())
     |> assign(:move_submitting, false)
     |> assign(:status_message, "")
     |> assign(:aliases, AccountMigration.list_aliases(user))
     |> load_move_state()}
  end

  @impl true
  def handle_event("confirm_identity", %{"reauth" => params}, socket) do
    user = socket.assigns.current_user

    result =
      with :ok <- RateLimits.check_reauth(user.id) do
        Auth.verify_reauthentication(
          user,
          params["password"],
          params["code"],
          socket.assigns.peer_ip,
          :account_aliases
        )
      end

    socket = assign(socket, :reauth_form, empty_reauth_form())

    case result do
      :ok ->
        {:noreply,
         socket
         |> assign(:reauth_until, System.monotonic_time(:second) + @reauth_seconds)
         |> put_flash(
           :info,
           gettext("Identity confirmed. You can manage your aliases for 5 minutes.")
         )
         |> push_event("focus", %{id: "account_alias_input"})}

      {:error, :rate_limited} ->
        {:noreply,
         put_flash(socket, :error, gettext("Too many attempts. Please try again later."))}

      {:error, {:throttled, seconds}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Too many failed attempts. Please try again in %{seconds} seconds.",
             seconds: seconds
           )
         )}

      {:error, :invalid_credentials} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Invalid credentials. Please try again."))
         |> push_event("focus", %{id: "reauth_password"})}
    end
  end

  def handle_event("add_alias", %{"alias" => %{"account" => input}}, socket) do
    with_reauth(socket, fn socket ->
      user = socket.assigns.current_user

      cond do
        socket.assigns.alias_lookup ->
          {:noreply, socket}

        RateLimits.check_account_alias(user.id) != :ok ->
          {:noreply,
           put_flash(socket, :error, gettext("Too many attempts. Please try again later."))}

        true ->
          {:noreply,
           socket
           |> assign(:alias_lookup, true)
           |> assign(:alias_form, to_form(%{"account" => input}, as: :alias))
           |> assign(:status_message, gettext("Looking up the account…"))
           |> start_async(:add_alias, fn -> AccountMigration.add_alias(user, input) end)}
      end
    end)
  end

  def handle_event("remove_alias", %{"ap-id" => ap_id}, socket) do
    with_reauth(socket, fn socket ->
      case AccountMigration.remove_alias(socket.assigns.current_user, ap_id) do
        {:ok, _user} ->
          {:noreply,
           socket
           |> reload_aliases()
           |> put_flash(:info, gettext("Alias removed."))
           |> assign(:status_message, gettext("Alias removed."))
           |> push_event("focus", %{id: "account-aliases-heading"})}

        {:error, :not_found} ->
          {:noreply, socket |> reload_aliases() |> put_flash(:error, gettext("Alias not found."))}
      end
    end)
  end

  def handle_event("request_move", %{"move" => params}, socket) do
    user = socket.assigns.current_user
    account = params["account"] || ""

    cond do
      socket.assigns.move_submitting ->
        {:noreply, socket}

      RateLimits.check_reauth(user.id) != :ok or RateLimits.check_account_alias(user.id) != :ok ->
        {:noreply, put_flash(socket, :error, move_error_message(:rate_limited))}

      true ->
        credentials = %{password: params["password"], code: params["code"]}

        opts = [
          ip_address: socket.assigns.peer_ip,
          session_id: socket.assigns.session_id,
          user_agent: socket.assigns.user_agent
        ]

        {:noreply,
         socket
         |> assign(:move_submitting, true)
         |> assign(:move_form, to_form(%{"account" => account}, as: :move))
         |> assign(:status_message, gettext("Checking the destination account…"))
         |> start_async(:request_move, fn ->
           AccountMigration.request_move(user, account, credentials, opts)
         end)}
    end
  end

  def handle_event("cancel_move", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with {move_id, ""} <- Integer.parse(to_string(id)),
         {:ok, _move} <- AccountMigration.cancel_move(user.id, move_id) do
      {:noreply,
       socket
       |> load_move_state()
       |> put_flash(:info, gettext("The move was cancelled."))
       |> assign(:status_message, gettext("The move was cancelled."))
       |> push_event("focus", %{id: "account-move-heading"})}
    else
      _ ->
        {:noreply,
         socket
         |> load_move_state()
         |> put_flash(:error, gettext("There is no pending move to cancel."))}
    end
  end

  @impl true
  def handle_async(:request_move, {:ok, result}, socket) do
    socket = socket |> assign(:move_submitting, false) |> assign(:move_form, empty_move_form())

    case result do
      {:ok, move} ->
        message =
          gettext("Move requested. It will be sent after %{time} unless you cancel it.",
            time: format_datetime(move.send_after)
          )

        {:noreply,
         socket
         |> load_move_state()
         |> put_flash(:info, message)
         |> assign(:status_message, message)
         |> push_event("focus", %{id: "account-move-heading"})}

      {:error, reason} ->
        message = move_error_message(reason)

        {:noreply,
         socket
         |> load_move_state()
         |> assign(
           :move_form,
           to_form(%{"account" => socket.assigns.move_form[:account].value}, as: :move)
         )
         |> put_flash(:error, message)
         |> assign(:status_message, message)
         |> push_event("focus", %{id: "account_move_account"})}
    end
  end

  def handle_async(:request_move, {:exit, _reason}, socket) do
    message = move_error_message(:unavailable)

    {:noreply,
     socket
     |> assign(:move_submitting, false)
     |> put_flash(:error, message)
     |> assign(:status_message, message)}
  end

  def handle_async(:add_alias, {:ok, result}, socket) do
    socket = assign(socket, :alias_lookup, false)

    case result do
      {:ok, _user, actor} ->
        label = "@#{actor.username}@#{actor.domain}"

        {:noreply,
         socket
         |> reload_aliases()
         |> assign(:alias_form, empty_alias_form())
         |> put_flash(:info, gettext("Alias %{label} added.", label: label))
         |> assign(:status_message, gettext("Alias %{label} added.", label: label))}

      {:error, reason} ->
        message = alias_error_message(reason)

        {:noreply,
         socket
         |> put_flash(:error, message)
         |> assign(:status_message, message)
         |> push_event("focus", %{id: "account_alias_input"})}
    end
  end

  def handle_async(:add_alias, {:exit, _reason}, socket) do
    message = alias_error_message(:not_found)

    {:noreply,
     socket
     |> assign(:alias_lookup, false)
     |> put_flash(:error, message)
     |> assign(:status_message, message)}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @doc false
  def alias_error_message(:invalid_input),
    do: gettext("Enter the account as @user@example.com or as its https:// address.")

  def alias_error_message(:not_found),
    do: gettext("That account could not be found. Check the address and try again.")

  def alias_error_message(:not_a_person),
    do: gettext("Only person accounts can be aliases, not groups, bots or servers.")

  def alias_error_message(:already_added), do: gettext("That account is already an alias.")

  def alias_error_message(:too_many_aliases),
    do:
      gettext("An account can have at most %{count} aliases.",
        count: AccountMigration.max_aliases()
      )

  def alias_error_message(:moved),
    do: gettext("This account has moved. Remove the redirect before changing aliases.")

  @doc false
  def move_error_message(reason)
      when reason in [:invalid_input, :not_found, :not_a_person],
      do: alias_error_message(reason)

  def move_error_message(:alias_not_claimed),
    do:
      gettext(
        "The destination account does not list this account as an alias yet. Add it there first, then try again."
      )

  def move_error_message(:target_moved),
    do: gettext("The destination account has itself moved. Choose its new account instead.")

  def move_error_message(:pending_move_exists),
    do: gettext("A move of this account is already pending.")

  def move_error_message(:moved), do: gettext("This account has already moved.")

  def move_error_message(:staff),
    do:
      gettext("Administrators and moderators cannot move their account. Ask to be demoted first.")

  def move_error_message(:board_moderator),
    do:
      gettext(
        "Board moderators cannot move their account. Ask to be removed as a moderator first."
      )

  def move_error_message({:recently_moved, at}),
    do:
      gettext("This account moved less than 30 days ago. You can move again after %{time}.",
        time: format_datetime(at)
      )

  def move_error_message(:totp_required),
    do: gettext("Enable two-factor authentication (TOTP) to move your account.")

  def move_error_message({:totp_too_new, days}),
    do:
      ngettext(
        "Two-factor authentication must be enabled for 7 days first. You can move in %{count} day.",
        "Two-factor authentication must be enabled for 7 days first. You can move in %{count} days.",
        days,
        count: days
      )

  def move_error_message(:bot), do: gettext("Bot accounts cannot move.")

  def move_error_message(:not_active),
    do: gettext("Only active accounts can move. Please contact an administrator.")

  def move_error_message(reason)
      when reason in [:rate_limited, :invalid_credentials] or
             (is_tuple(reason) and elem(reason, 0) == :throttled),
      do: DataExportLive.error_message(reason)

  def move_error_message(_),
    do: gettext("The move could not be requested. Please try again later.")

  @doc false
  def move_status_label("pending"), do: gettext("Waiting")
  def move_status_label("sent"), do: gettext("Sent")
  def move_status_label("cancelled"), do: gettext("Cancelled")
  def move_status_label("failed"), do: gettext("Failed")

  defp load_move_state(socket) do
    user_id = socket.assigns.current_user.id
    fresh = Auth.get_user(user_id)
    history = AccountMigration.list_move_history(user_id)
    summary = AccountMigration.active_move_summary(user_id)

    socket
    |> assign(:move_eligibility, AccountMigration.move_eligibility(fresh))
    |> assign(:totp_enabled, fresh.totp_enabled)
    |> assign(:active_move, summary)
    # The layout banner reads this assign; keep it in step with the page.
    |> assign(:active_account_move, summary)
    |> assign(:move_history, history)
    |> assign(
      :target_labels,
      AccountMigration.target_labels(Enum.map(history, & &1.target_ap_id))
    )
  end

  defp with_reauth(socket, fun) do
    until = socket.assigns.reauth_until

    if until && System.monotonic_time(:second) < until do
      fun.(socket)
    else
      {:noreply,
       socket
       |> assign(:reauth_until, nil)
       |> put_flash(:error, gettext("Please confirm your identity before managing aliases."))
       |> push_event("focus", %{id: "reauth_password"})}
    end
  end

  defp reload_aliases(socket) do
    assign(socket, :aliases, AccountMigration.list_aliases(socket.assigns.current_user))
  end

  defp alias_display(%{actor: %{username: username, domain: domain}}),
    do: "@#{username}@#{domain}"

  defp alias_display(%{ap_id: ap_id}), do: ap_id

  defp empty_reauth_form, do: to_form(%{"password" => "", "code" => ""}, as: :reauth)
  defp empty_alias_form, do: to_form(%{"account" => ""}, as: :alias)
  defp empty_move_form, do: to_form(%{"account" => ""}, as: :move)
  defp cancel_reason_label(reason), do: DataExportLive.cancel_reason_label(reason)
end
