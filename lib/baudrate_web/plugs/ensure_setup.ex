defmodule BaudrateWeb.Plugs.EnsureSetup do
  @moduledoc """
  Plug that gates access based on whether initial setup has been completed.

  ## Redirect Logic

    * **Setup not completed + not on `/setup`** → redirect to `/setup`
      (forces the setup wizard before any other page is accessible)
    * **Setup completed + on `/setup`** → redirect to `/`
      (prevents re-running setup after it's done)
    * **Otherwise** → pass through

  Checks `Setup.setup_completed?/0` on every request (queries the `settings`
  table for `setup_completed = "true"`).
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
