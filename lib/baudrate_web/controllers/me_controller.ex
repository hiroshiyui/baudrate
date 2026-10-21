defmodule BaudrateWeb.MeController do
  @moduledoc """
  Redirects `/me` to the signed-in member's own profile, `/users/:username`.

  A short address to bookmark or type; the main menu links the profile
  directly, so following it costs no extra hop.
  """

  use BaudrateWeb, :controller

  alias Baudrate.Auth

  @doc """
  Redirects to the member's profile, or to `/login` for a guest.

  **302 and `no-store`, never 301:** the target depends on who is asking, so
  neither the browser nor a cache may remember it. A banned or deleted
  account's profile answers 404, so such a session is sent to `/login` like a
  guest.
  """
  def show(conn, _params) do
    case current_user(conn) do
      %{status: status, username: username} when status not in ["banned", "deleted"] ->
        conn
        |> put_resp_header("cache-control", "private, no-store")
        |> redirect(to: ~p"/users/#{username}")

      _ ->
        redirect(conn, to: ~p"/login")
    end
  end

  defp current_user(conn) do
    with token when is_binary(token) <- get_session(conn, :session_token),
         {:ok, user} <- Auth.get_user_by_session_token(token) do
      user
    else
      _ -> nil
    end
  end
end
