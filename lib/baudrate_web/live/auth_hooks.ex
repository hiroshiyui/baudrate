defmodule BaudrateWeb.AuthHooks do
  @moduledoc """
  LiveView on_mount hooks for authentication.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  alias Baudrate.Auth

  def on_mount(:require_auth, _params, session, socket) do
    user_id = session["user_id"]
    totp_verified = session["totp_verified"]

    cond do
      is_nil(user_id) ->
        {:halt, redirect(socket, to: "/login")}

      totp_verified != true ->
        user = Auth.get_user(user_id)

        if user do
          case Auth.login_next_step(user) do
            :totp_verify -> {:halt, redirect(socket, to: "/totp/verify")}
            :totp_setup -> {:halt, redirect(socket, to: "/totp/setup")}
            :authenticated -> {:halt, redirect(socket, to: "/login")}
          end
        else
          {:halt, redirect(socket, to: "/login")}
        end

      true ->
        user = Auth.get_user(user_id)

        if user do
          {:cont, assign(socket, :current_user, user)}
        else
          {:halt, redirect(socket, to: "/login")}
        end
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
    user_id = session["user_id"]
    totp_verified = session["totp_verified"]

    if user_id && totp_verified == true do
      {:halt, redirect(socket, to: "/")}
    else
      {:cont, socket}
    end
  end
end
