defmodule BaudrateWeb.HealthDetail do
  @moduledoc """
  Serves the detailed health report (`Baudrate.Health`) on its own HTTP
  listener, bound to `127.0.0.1` and started only when `HEALTH_DETAIL_PORT`
  is set.

      curl -s http://127.0.0.1:4001/health

  Answers `200` when every check passes and `503` when one fails, with the
  report as JSON either way, so a monitor can alert on the status code alone.

  ## Why a separate listener

  The public endpoint cannot tell a local request from a remote one: nginx
  runs on the same host and proxies every visitor from `127.0.0.1`, so "only
  from localhost" on a public path would admit the whole internet. A listener
  that nginx does not proxy, bound to the loopback address, is reachable only
  from the host itself. The address is fixed in `child_spec/1` and is not
  configurable, so a configuration change cannot expose it.

  The plug answers `GET /health` and nothing else. It has no session, cookies
  or router, and the report holds counts and ages only.
  """

  @behaviour Plug

  import Plug.Conn

  @loopback {127, 0, 0, 1}

  @doc """
  The listener's child spec, or `nil` when no port is configured. Options:
  `:port` (defaults to the configured `HEALTH_DETAIL_PORT`; `0` picks a free
  port, for tests).
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec() | nil
  def child_spec(opts \\ []) do
    case Keyword.get_lazy(opts, :port, &configured_port/0) do
      nil ->
        nil

      port when is_integer(port) and port >= 0 ->
        Supervisor.child_spec(
          {Bandit,
           plug: __MODULE__,
           scheme: :http,
           ip: @loopback,
           port: port,
           thousand_island_options: [num_acceptors: 2]},
          id: __MODULE__
        )
    end
  end

  defp configured_port do
    Application.get_env(:baudrate, __MODULE__, []) |> Keyword.get(:port)
  end

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: "GET", path_info: ["health"]} = conn, _opts) do
    report = Baudrate.Health.report()
    status = if report.status == :ok, do: 200, else: 503

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, Jason.encode_to_iodata!(report))
  end

  def call(conn, _opts) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "Not Found")
  end
end
