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

  Authorization and validation live in `Baudrate.AccountMigration`.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.{AccountMigration, Auth}
  alias BaudrateWeb.RateLimits

  import BaudrateWeb.Helpers, only: [extract_peer_ip: 1]

  @reauth_seconds 300

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:page_title, gettext("Account Migration"))
     |> assign(:peer_ip, if(connected?(socket), do: extract_peer_ip(socket), else: "unknown"))
     |> assign(:reauth_until, nil)
     |> assign(:reauth_form, empty_reauth_form())
     |> assign(:alias_form, empty_alias_form())
     |> assign(:alias_lookup, false)
     |> assign(:status_message, "")
     |> assign(:aliases, AccountMigration.list_aliases(user))}
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

  @impl true
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
end
