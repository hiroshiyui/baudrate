defmodule BaudrateWeb.Plugs.EnsureSetup do
  @moduledoc """
  Redirects all routes to /setup until initial setup is complete.
  After setup, blocks access to /setup and redirects to /.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  def init(opts), do: opts

  def call(conn, _opts) do
    setup_completed = Baudrate.Setup.setup_completed?()

    cond do
      not setup_completed and not setup_path?(conn) ->
        conn
        |> redirect(to: "/setup")
        |> halt()

      setup_completed and setup_path?(conn) ->
        conn
        |> redirect(to: "/")
        |> halt()

      true ->
        conn
    end
  end

  defp setup_path?(conn) do
    conn.request_path == "/setup" or String.starts_with?(conn.request_path, "/setup/")
  end
end
