defmodule Baudrate.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # First, so the rest of the boot is logged in the configured format.
    Baudrate.Logger.JSONFormatter.install_if_configured()

    # Says so when secrets at rest are still keyed off SECRET_KEY_BASE, which
    # is what stops it being rotated (ADR 0038).
    Baudrate.Crypto.Keyring.warn_unseparated()

    children =
      [
        BaudrateWeb.Telemetry,
        Baudrate.Repo,
        # Baudrate runs on one node (ADR 0033): the ETS caches, nonces,
        # challenges and rate limits below are complete on their own, and every
        # worker runs exactly once. There is deliberately no cluster discovery.
        {Phoenix.PubSub, name: Baudrate.PubSub},
        # Before the workers that beat into it.
        Baudrate.Health.Heartbeat,
        Baudrate.Auth.SessionCleaner,
        Baudrate.Auth.WebAuthnChallenges,
        Baudrate.DataPortability.DownloadNonces,
        Baudrate.Setup.SettingsCache,
        # Logs a banner when the setup wizard is locked by a missing
        # INSTALLATION_KEY. Logging only — never raises, so a database blip
        # cannot turn a warning into a failed boot.
        Supervisor.child_spec(
          {Task, &Baudrate.Setup.InstallationKey.log_boot_status/0},
          id: :installation_key_check,
          restart: :temporary
        ),
        Baudrate.Content.BoardCache,
        Baudrate.Media.NegativeCache,
        {BaudrateWeb.RateLimit, [clean_period: :timer.minutes(5)]},
        {Task.Supervisor, name: Baudrate.Federation.TaskSupervisor},
        Baudrate.Federation.DomainBlockCache,
        Baudrate.Federation.DeliveryWorker,
        Baudrate.Federation.InboundWorker,
        Baudrate.Federation.StaleActorCleaner,
        Baudrate.Bots.SyndicationFeedWorker,
        # The detailed health report on 127.0.0.1, when HEALTH_DETAIL_PORT is set.
        BaudrateWeb.HealthDetail.child_spec(),
        # Start to serve requests, typically the last entry
        BaudrateWeb.Endpoint
      ]
      |> Enum.reject(&is_nil/1)

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
