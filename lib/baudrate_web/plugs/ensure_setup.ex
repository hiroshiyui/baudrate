defmodule BaudrateWeb.Plugs.EnsureSetup do
  @moduledoc """
  Plug that gates access based on whether initial setup has been completed.

  ## Redirect Logic

    * **Setup not completed + `INSTALLATION_KEY` missing while enforced** →
      **503**, halted. See below.
    * **Setup not completed + not on `/setup`** → redirect to `/setup`
      (forces the setup wizard before any other page is accessible)
    * **Setup completed + on `/setup`** → redirect to `/`
      (prevents re-running setup after it's done)
    * **Otherwise** → pass through

  Checks `Setup.setup_completed?/0` on every request (queries the `settings`
  table for `setup_completed = "true"`).

  ## Setup lock

  Between deploy and the completion of the wizard, `/setup` grants admin rights
  to whoever reaches it first, and `INSTALLATION_KEY` is the only thing gating
  that window. When the key is enforced (production) but not configured, this
  plug refuses **every** browser route with a 503 rather than serve the wizard.
  Halting everything is deliberate: an un-set-up instance has nothing else to
  serve, and it makes the misconfiguration impossible to miss.

  Once setup completes the lock lifts, so an operator who removed the key
  afterwards — as `doc/sysop.md` has always instructed — is unaffected. The
  `:api` and ActivityPub pipelines do not include this plug.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  require Logger

  alias Baudrate.Setup.InstallationKey

  def init(opts), do: opts

  def call(conn, _opts) do
    setup_completed = Baudrate.Setup.setup_completed?()

    cond do
      not setup_completed and InstallationKey.status() == {:error, :missing} ->
        Logger.error(
          "setup.locked: INSTALLATION_KEY is not configured; refusing to serve the setup wizard"
        )

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(
          503,
          "Setup is locked. The server operator must set INSTALLATION_KEY and restart."
        )
        |> halt()

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
