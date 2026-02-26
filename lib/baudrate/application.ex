defmodule Baudrate.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      BaudrateWeb.Telemetry,
      Baudrate.Repo,
      {DNSCluster, query: Application.get_env(:baudrate, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Baudrate.PubSub},
      Baudrate.Auth.SessionCleaner,
      {Task.Supervisor, name: Baudrate.Federation.TaskSupervisor},
      Baudrate.Federation.DomainBlockCache,
      Baudrate.Federation.DeliveryWorker,
      Baudrate.Federation.StaleActorCleaner,
      # Start to serve requests, typically the last entry
      BaudrateWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Baudrate.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BaudrateWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
