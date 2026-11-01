defmodule BaudrateWeb.Plugs.ForgetRevokedSession do
  @moduledoc """
  Removes a revoked session's keys from the cookie on the sign-in pages.

  When a session is revoked, its open pages are redirected to `/login`
  (`BaudrateWeb.AuthHooks`), and a second later the session's sockets are
  closed by a `"disconnect"` broadcast to its `live_socket_id`. The browser's
  cookie still names that `live_socket_id`, so without this plug the sign-in
  page it lands on would open a socket under the same id, be closed by that
  backstop, and reload 5-10 s later under whoever was typing a password.

  Only the auth keys go (`session_token`, `refresh_token`, `refreshed_at`,
  `live_socket_id`); the rest of the cookie, including the flash that says
  why the member is here, stays. The session row is looked up only when the
  cookie carries a token, on the few pages this plug is piped through.
  """

  import Plug.Conn

  @auth_keys [:session_token, :refresh_token, :refreshed_at, :live_socket_id]

  def init(opts), do: opts

  def call(conn, _opts) do
    with token when is_binary(token) <- get_session(conn, :session_token),
         nil <- Baudrate.Auth.session_id_by_token(token) do
      Enum.reduce(@auth_keys, conn, &delete_session(&2, &1))
    else
      _ -> conn
    end
  end
end
