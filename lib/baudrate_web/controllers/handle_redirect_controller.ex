defmodule BaudrateWeb.HandleRedirectController do
  @moduledoc """
  Redirects `/@username` URLs to the canonical `/users/:username` path.

  Mastodon and other ActivityPub implementations use the `url` field from the
  Person actor JSON to build profile links shown to users. Baudrate sets this
  to `/@username`, so this controller handles those URLs by redirecting to
  `/users/:username`.
  """

  use BaudrateWeb, :controller

  alias Baudrate.Auth

  @doc """
  Redirects `/@username` to `/users/:username`, or returns 404.
  """
  def show(conn, %{"handle" => handle}) do
    case Auth.get_user_by_username(handle) do
      %{username: username} ->
        redirect(conn, to: ~p"/users/#{username}")

      nil ->
        conn
        |> put_status(:not_found)
        |> put_view(BaudrateWeb.ErrorHTML)
        |> render(:"404")
    end
  end
end
