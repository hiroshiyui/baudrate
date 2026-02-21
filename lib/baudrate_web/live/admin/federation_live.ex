defmodule BaudrateWeb.Admin.FederationLive do
  @moduledoc """
  LiveView for the admin federation dashboard.

  Displays known remote instances with stats, delivery queue status,
  and per-board federation controls. Only accessible to admin users.
  """

  use BaudrateWeb, :live_view

  on_mount {BaudrateWeb.AuthHooks, :require_admin}

  alias Baudrate.Content
  alias Baudrate.Setup
  alias Baudrate.Federation.{DeliveryStats, InstanceStats}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load_dashboard(socket)}
  end

  @impl true
  def handle_event("retry_job", %{"id" => id}, socket) do
    case DeliveryStats.retry_job(String.to_integer(id)) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, gettext("Job queued for retry.")) |> load_dashboard()}
      {:error, _} -> {:noreply, put_flash(socket, :error, gettext("Job not found."))}
    end
  end

  def handle_event("abandon_job", %{"id" => id}, socket) do
    case DeliveryStats.abandon_job(String.to_integer(id)) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, gettext("Job abandoned.")) |> load_dashboard()}
      {:error, _} -> {:noreply, put_flash(socket, :error, gettext("Job not found."))}
    end
  end

  def handle_event("block_domain", %{"domain" => domain}, socket) do
    current = Setup.get_setting("ap_domain_blocklist") || ""

    existing =
      current
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.map(&String.downcase/1)
      |> MapSet.new()

    unless MapSet.member?(existing, String.downcase(domain)) do
      new_list =
        if current == "",
          do: domain,
          else: current <> ", " <> domain

      Setup.set_setting("ap_domain_blocklist", new_list)
    end

    {:noreply,
     socket
     |> put_flash(:info, gettext("Domain %{domain} has been blocked.", domain: domain))
     |> load_dashboard()}
  end

  def handle_event("toggle_board_federation", %{"id" => id}, socket) do
    board = Baudrate.Repo.get!(Content.Board, String.to_integer(id))
    new_value = !board.ap_enabled

    board
    |> Ecto.Changeset.change(ap_enabled: new_value)
    |> Baudrate.Repo.update!()

    {:noreply,
     socket
     |> put_flash(:info, gettext("Federation %{action} for %{board}.",
       action: if(new_value, do: gettext("enabled"), else: gettext("disabled")),
       board: board.name
     ))
     |> load_dashboard()}
  end

  defp load_dashboard(socket) do
    instances = InstanceStats.list_instances()
    delivery_counts = DeliveryStats.status_counts()
    failed_jobs = DeliveryStats.list_actionable_jobs(20)
    error_rate = DeliveryStats.error_rate_24h()
    boards = Content.list_top_boards()

    assign(socket,
      instances: instances,
      delivery_counts: delivery_counts,
      failed_jobs: failed_jobs,
      error_rate: error_rate,
      boards: boards
    )
  end
end
