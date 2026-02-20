defmodule BaudrateWeb.AuthHooks do
  @moduledoc """
  LiveView on_mount hooks for authentication.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  alias Baudrate.Auth

  def on_mount(:require_auth, _params, session, socket) do
    session_token = session["session_token"]

    if session_token do
      case Auth.get_user_by_session_token(session_token) do
        {:ok, user} ->
          {:cont, assign(socket, :current_user, user)}

        {:error, _reason} ->
          {:halt, redirect(socket, to: "/login")}
      end
    else
      {:halt, redirect(socket, to: "/login")}
    end
  end

  def on_mount(:require_password_auth, _params, session, socket) do
    user_id = session["user_id"]

    if user_id do
      user = Auth.get_user(user_id)

      if user do
        {:cont, assign(socket, :current_user, user)}
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
        {:ok, _user} -> {:halt, redirect(socket, to: "/")}
        {:error, _} -> {:cont, socket}
      end
    else
      {:cont, socket}
    end
  end
end
