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

  **301, not 302:** this is a permanent alias for the canonical profile path,
  not a temporary one, and `/users/:username` carries the canonical link that
  settles it either way (ADR 0057).

  A banned account answers 404 here too, exactly as the profile page does —
  the two cases must not be distinguishable.
  """
  def show(conn, %{"handle" => handle}) do
    case Auth.get_user_by_username(handle) do
      %{status: "banned"} ->
        not_found(conn)

      %{username: username} ->
        conn
        |> put_status(:moved_permanently)
        |> redirect(to: ~p"/users/#{username}")

      nil ->
        not_found(conn)
    end
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> put_view(BaudrateWeb.ErrorHTML)
    |> render(:"404")
  end
end
