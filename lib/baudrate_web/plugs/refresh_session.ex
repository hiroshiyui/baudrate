defmodule BaudrateWeb.Plugs.RefreshSession do
  @moduledoc """
  Plug that rotates session and refresh tokens periodically.

  ## Rotation Interval

  Tokens are rotated when `refreshed_at` is more than 1 day (86,400 seconds)
  old. On successful rotation, both `session_token` and `refresh_token` in the
  cookie are replaced with new values, and `refreshed_at` is updated.

  ## Failure Behavior

  If rotation fails (e.g., refresh token not found, session expired), the
  entire cookie session is dropped (`configure_session(drop: true)`), which
  forces the user to re-authenticate on the next request.

  If session data is missing or malformed (no tokens, no timestamp), the plug
  passes through without action.
  """

  import Plug.Conn

  @refresh_interval_seconds 86_400

  def init(opts), do: opts

  def call(conn, _opts) do
    session_token = get_session(conn, :session_token)
    refresh_token = get_session(conn, :refresh_token)
    refreshed_at_str = get_session(conn, :refreshed_at)

    with true <-
           is_binary(session_token) and is_binary(refresh_token) and is_binary(refreshed_at_str),
         {:ok, refreshed_at, _} <- DateTime.from_iso8601(refreshed_at_str),
         true <- needs_refresh?(refreshed_at) do
      case Baudrate.Auth.refresh_user_session(refresh_token) do
        {:ok, new_session_token, new_refresh_token} ->
          conn
          |> put_session(:session_token, new_session_token)
          |> put_session(:refresh_token, new_refresh_token)
          |> put_session(:refreshed_at, DateTime.utc_now() |> DateTime.to_iso8601())

        {:error, _reason} ->
          configure_session(conn, drop: true)
      end
    else
      _ -> conn
    end
  end

  defp needs_refresh?(refreshed_at) do
    DateTime.diff(DateTime.utc_now(), refreshed_at, :second) >= @refresh_interval_seconds
  end
end
