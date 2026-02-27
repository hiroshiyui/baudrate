defmodule BaudrateWeb.SandboxHook do
  @moduledoc """
  LiveView `on_mount` hook for Ecto SQL sandbox in browser tests.

  Reads BeamMetadata encoded in the user-agent string (injected by
  `Phoenix.Ecto.SQL.Sandbox.put_beam_metadata/2` in Wallaby tests) and calls
  `Phoenix.Ecto.SQL.Sandbox.allow/2` so the LiveView process can share the
  test's database connection.

  Only active when `config :baudrate, :sql_sandbox, true` (test environment).
  """

  import Phoenix.LiveView

  def on_mount(:default, _params, _session, socket) do
    allow_sandbox(socket)
    {:cont, socket}
  end

  defp allow_sandbox(socket) do
    %{assigns: %{__changed__: _}} = socket

    case get_connect_info(socket, :user_agent) do
      user_agent when is_binary(user_agent) ->
        Phoenix.Ecto.SQL.Sandbox.allow(user_agent, Ecto.Adapters.SQL.Sandbox)

      _ ->
        :ok
    end
  end
end
