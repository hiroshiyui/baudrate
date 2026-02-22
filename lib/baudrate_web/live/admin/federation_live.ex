defmodule BaudrateWeb.Admin.FederationLive do
  @moduledoc """
  LiveView for the admin federation dashboard.

  Displays known remote instances with stats, delivery queue status,
  and per-board federation controls. Only accessible to admin users.
  """

  use BaudrateWeb, :live_view

  on_mount {BaudrateWeb.AuthHooks, :require_admin}

  alias Baudrate.{Content, Moderation, Setup}
  alias Baudrate.Federation
  alias Baudrate.Federation.{BlocklistAudit, DeliveryStats, InstanceStats}

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

  def handle_event("rotate_keys", %{"type" => type, "id" => id}, socket) do
    case rotate_by_type(type, id) do
      {:ok, _} ->
        Moderation.log_action(socket.assigns.current_user.id, "rotate_keys",
          target_type: type,
          target_id: parse_target_id(id),
          details: %{type: type}
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Keys rotated successfully."))
         |> load_dashboard()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Key rotation failed."))}
    end
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

  def handle_event("audit_blocklist", _params, socket) do
    case BlocklistAudit.audit() do
      {:ok, result} ->
        {:noreply, assign(socket, audit_result: result)}

      {:error, :no_audit_url} ->
        {:noreply, put_flash(socket, :error, gettext("No blocklist audit URL configured. Set it in Admin Settings."))}

      {:error, {:fetch_failed, _}} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to fetch external blocklist."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Blocklist audit failed."))}
    end
  end

  def handle_event("add_missing_domain", %{"domain" => domain}, socket) do
    add_domain_to_blocklist(domain)

    Moderation.log_action(socket.assigns.current_user.id, "block_domain",
      details: %{domain: domain, source: "audit"}
    )

    # Re-run audit to refresh results
    case BlocklistAudit.audit() do
      {:ok, result} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Domain %{domain} added to blocklist.", domain: domain))
         |> assign(audit_result: result)}

      _ ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Domain %{domain} added to blocklist.", domain: domain))
         |> assign(audit_result: nil)}
    end
  end

  def handle_event("add_all_missing", _params, socket) do
    case socket.assigns[:audit_result] do
      %{missing: missing} when missing != [] ->
        Enum.each(missing, &add_domain_to_blocklist/1)

        Moderation.log_action(socket.assigns.current_user.id, "block_domain",
          details: %{domains: missing, source: "audit_bulk", count: length(missing)}
        )

        case BlocklistAudit.audit() do
          {:ok, result} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Added %{count} domains to blocklist.", count: length(missing)))
             |> assign(audit_result: result)}

          _ ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Added %{count} domains to blocklist.", count: length(missing)))
             |> assign(audit_result: nil)}
        end

      _ ->
        {:noreply, socket}
    end
  end

  defp add_domain_to_blocklist(domain) do
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
  end

  defp rotate_by_type("site", _id), do: Federation.rotate_keys(:site, nil)

  defp rotate_by_type("board", id) do
    board = Baudrate.Repo.get!(Content.Board, String.to_integer(id))
    Federation.rotate_keys(:board, board)
  end

  defp rotate_by_type("user", id) do
    user = Baudrate.Repo.get!(Baudrate.Setup.User, String.to_integer(id))
    Federation.rotate_keys(:user, user)
  end

  defp rotate_by_type(_, _), do: {:error, :invalid_type}

  defp parse_target_id("site"), do: nil
  defp parse_target_id(id), do: String.to_integer(id)

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
      boards: boards,
      audit_result: socket.assigns[:audit_result]
    )
  end
end
