defmodule BaudrateWeb.AuthHooks do
  @moduledoc """
  LiveView `on_mount` hooks for authentication enforcement.

  Four hooks are provided, each attached to `live_session` scopes in the router:

    * `:require_auth` — requires a fully authenticated session (`session_token`
      present and valid). Used for the `:authenticated` live_session. Assigns
      `@current_user` on success, redirects to `/login` on failure.
      Also resolves the user's preferred locale from `user.preferred_locales`
      and sets Gettext locale + `@locale` assign.

    * `:optional_auth` — loads the user if a valid session exists, but does not
      redirect if unauthenticated. Assigns `@current_user` (may be `nil`).
      Used for pages that are accessible to both guests and authenticated users.
      Also resolves locale when a user is present.

    * `:require_password_auth` — requires password-level auth only (`user_id`
      in session). Used for the `:totp` live_session where the user has passed
      password auth but hasn't completed TOTP yet. Assigns `@current_user`.
      Also resolves the user's preferred locale.

    * `:redirect_if_authenticated` — if the user already has a valid
      `session_token`, redirects to `/`. Used for the `:public` live_session
      (login page) to prevent authenticated users from seeing the login form.
  """

  import Phoenix.LiveView
  import Phoenix.Component
  use Gettext, backend: BaudrateWeb.Gettext

  alias Baudrate.Auth
  alias Baudrate.Messaging
  alias BaudrateWeb.MarkdownPreviewHook
  alias BaudrateWeb.UnreadDmCountHook

  def on_mount(:require_auth, _params, session, socket) do
    session_token = session["session_token"]

    if session_token do
      case Auth.get_user_by_session_token(session_token) do
        {:ok, user} ->
          if user.status == "banned" do
            {:halt,
             socket
             |> put_flash(:error, gettext("Your account has been banned."))
             |> redirect(to: "/login")}
          else
            locale = resolve_user_locale(user)

            socket =
              socket
              |> assign(:current_user, user)
              |> assign(:locale, locale)
              |> assign(:unread_dm_count, Messaging.unread_count(user))
              |> MarkdownPreviewHook.attach()
              |> UnreadDmCountHook.attach(user)

            {:cont, socket}
          end

        {:error, _reason} ->
          {:halt, redirect(socket, to: "/login")}
      end
    else
      {:halt, redirect(socket, to: "/login")}
    end
  end

  def on_mount(:optional_auth, _params, session, socket) do
    session_token = session["session_token"]

    if session_token do
      case Auth.get_user_by_session_token(session_token) do
        {:ok, user} ->
          if user.status == "banned" do
            {:cont, assign(socket, :current_user, nil)}
          else
            locale = resolve_user_locale(user)

            socket =
              socket
              |> assign(:current_user, user)
              |> assign(:locale, locale)
              |> assign(:unread_dm_count, Messaging.unread_count(user))
              |> MarkdownPreviewHook.attach()
              |> UnreadDmCountHook.attach(user)

            {:cont, socket}
          end

        {:error, _reason} ->
          {:cont, socket |> assign(:current_user, nil) |> MarkdownPreviewHook.attach()}
      end
    else
      {:cont, socket |> assign(:current_user, nil) |> MarkdownPreviewHook.attach()}
    end
  end

  def on_mount(:require_password_auth, _params, session, socket) do
    user_id = session["user_id"]

    if user_id do
      user = Auth.get_user(user_id)

      if user && user.status != "banned" do
        locale = resolve_user_locale(user)

        socket =
          socket
          |> assign(:current_user, user)
          |> assign(:locale, locale)

        {:cont, socket}
      else
        {:halt, redirect(socket, to: "/login")}
      end
    else
      {:halt, redirect(socket, to: "/login")}
    end
  end

  def on_mount(:redirect_if_authenticated, _params, session, socket) do
    session_token = session["session_token"]

    if session_token do
      case Auth.get_user_by_session_token(session_token) do
        {:ok, user} ->
          if user.status == "banned" do
            {:cont, socket}
          else
            {:halt, redirect(socket, to: "/")}
          end

        {:error, _} ->
          {:cont, socket}
      end
    else
      {:cont, socket}
    end
  end

  def on_mount(:require_admin, _params, _session, socket) do
    if socket.assigns[:current_user] && socket.assigns.current_user.role.name == "admin" do
      {:cont, socket}
    else
      {:halt,
       socket
       |> put_flash(:error, gettext("Access denied."))
       |> redirect(to: "/")}
    end
  end

  defp resolve_user_locale(user) do
    case BaudrateWeb.Locale.resolve_from_preferences(user.preferred_locales) do
      nil ->
        Gettext.get_locale()

      locale ->
        Gettext.put_locale(locale)
        locale
    end
  end
end
