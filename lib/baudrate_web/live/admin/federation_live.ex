defmodule BaudrateWeb.Admin.FederationLive do
  @moduledoc """
  LiveView for the admin federation dashboard.

  Displays known remote instances with stats, delivery queue status,
  and per-board federation controls. Only accessible to admin users.
  """

  use BaudrateWeb, :live_view

  on_mount {BaudrateWeb.AuthHooks, :require_admin}

  alias Baudrate.{Auth, Content, Moderation}
  alias Baudrate.Content.Board
  alias Baudrate.Federation
  alias Baudrate.Federation.{BlocklistAudit, DeliveryStats, DomainBlocks, InstanceStats}
  import BaudrateWeb.Helpers, only: [parse_id: 1, translate_role: 1, translate_delivery_status: 1]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(load_dashboard(socket), :page_title, gettext("Admin Federation"))}
  end

  @impl true
  def handle_event("retry_job", %{"id" => id}, socket) do
    case parse_id(id) do
      :error ->
        {:noreply, socket}

      {:ok, job_id} ->
        case DeliveryStats.retry_job(job_id) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Job queued for retry."))
             |> load_dashboard()
             |> push_event("focus", %{id: "delivery-queue-heading"})}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Job not found."))}
        end
    end
  end

  @impl true
  def handle_event("abandon_job", %{"id" => id}, socket) do
    case parse_id(id) do
      :error ->
        {:noreply, socket}

      {:ok, job_id} ->
        case DeliveryStats.abandon_job(job_id) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Job abandoned."))
             |> load_dashboard()
             |> push_event("focus", %{id: "delivery-queue-heading"})}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Job not found."))}
        end
    end
  end

  @impl true
  def handle_event("block_domain", %{"domain" => domain}, socket) do
    case DomainBlocks.block_domain(domain, socket.assigns.current_user) do
      {:ok, block} ->
        Moderation.log_action(socket.assigns.current_user.id, "block_domain",
          details: %{domain: block.domain, source: "instances"}
        )

        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Domain %{domain} has been blocked.", domain: block.domain)
         )
         |> load_dashboard()}

      {:error, :already_blocked} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Domain %{domain} is already blocked.", domain: domain))
         |> load_dashboard()}

      {:error, _changeset} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("%{domain} is not a domain we can block.", domain: domain)
         )}
    end
  end

  @impl true
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

  @impl true
  def handle_event("toggle_board_federation", %{"id" => id}, socket) do
    case parse_id(id) do
      :error -> {:noreply, socket}
      {:ok, board_id} -> do_toggle_federation(socket, board_id)
    end
  end

  @impl true
  def handle_event("audit_blocklist", _params, socket) do
    case BlocklistAudit.audit() do
      {:ok, result} ->
        {:noreply, assign(socket, audit_result: result)}

      {:error, :no_audit_url} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("No blocklist audit URL configured. Set it in Admin Settings.")
         )}

      {:error, {:fetch_failed, _}} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to fetch external blocklist."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Blocklist audit failed."))}
    end
  end

  @impl true
  def handle_event("add_missing_domain", %{"domain" => domain}, socket) do
    # Audit the block only when one happened. The old code logged an entry for
    # a domain that was already blocked, and skipped one on the instance list.
    case DomainBlocks.block_domain(domain, socket.assigns.current_user) do
      {:ok, block} ->
        Moderation.log_action(socket.assigns.current_user.id, "block_domain",
          details: %{domain: block.domain, source: "audit"}
        )

      _ ->
        :ok
    end

    # Re-run audit to refresh results
    case BlocklistAudit.audit() do
      {:ok, result} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Domain %{domain} added to blocklist.", domain: domain))
         |> assign(audit_result: result)
         |> push_event("focus", %{id: "blocklist-audit-heading"})}

      _ ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Domain %{domain} added to blocklist.", domain: domain))
         |> assign(audit_result: nil)
         |> push_event("focus", %{id: "blocklist-audit-heading"})}
    end
  end

  @impl true
  def handle_event("add_all_missing", _params, socket) do
    case socket.assigns[:audit_result] do
      %{missing: missing} when missing != [] ->
        blocked =
          Enum.flat_map(missing, fn domain ->
            case DomainBlocks.block_domain(domain, socket.assigns.current_user) do
              {:ok, block} -> [block.domain]
              _ -> []
            end
          end)

        if blocked != [] do
          Moderation.log_action(socket.assigns.current_user.id, "block_domain",
            details: %{domains: blocked, source: "audit_bulk", count: length(blocked)}
          )
        end

        case BlocklistAudit.audit() do
          {:ok, result} ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               gettext("Added %{count} domains to blocklist.", count: length(blocked))
             )
             |> assign(audit_result: result)
             |> push_event("focus", %{id: "blocklist-audit-heading"})}

          _ ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               gettext("Added %{count} domains to blocklist.", count: length(blocked))
             )
             |> assign(audit_result: nil)
             |> push_event("focus", %{id: "blocklist-audit-heading"})}
        end

      _ ->
        {:noreply, socket}
    end
  end

  defp do_toggle_federation(socket, board_id) do
    case Content.get_board(board_id) do
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, gettext("Board not found."))}

      {:ok, board} ->
        case Content.toggle_board_federation(board) do
          {:ok, updated} ->
            Moderation.log_action(socket.assigns.current_user.id, "toggle_board_federation",
              target_type: "board",
              target_id: updated.id,
              details: %{name: updated.name, ap_enabled: updated.ap_enabled}
            )

            {:noreply,
             socket
             |> put_flash(
               :info,
               gettext("Federation %{action} for %{board}.",
                 action:
                   if(updated.ap_enabled, do: gettext("enabled"), else: gettext("disabled")),
                 board: updated.name
               )
             )
             |> load_dashboard()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to update board."))}
        end
    end
  end

  defp rotate_by_type("site", _id), do: Federation.rotate_keys(:site, nil)

  defp rotate_by_type("board", id) do
    case parse_id(id) do
      {:ok, board_id} ->
        case Content.get_board(board_id) do
          {:error, :not_found} -> {:error, :not_found}
          {:ok, board} -> Federation.rotate_keys(:board, board)
        end

      :error ->
        {:error, :invalid_id}
    end
  end

  defp rotate_by_type("user", id) do
    case parse_id(id) do
      {:ok, user_id} ->
        case Auth.get_user(user_id) do
          nil -> {:error, :not_found}
          user -> Federation.rotate_keys(:user, user)
        end

      :error ->
        {:error, :invalid_id}
    end
  end

  defp rotate_by_type(_, _), do: {:error, :invalid_type}

  defp parse_target_id("site"), do: nil

  defp parse_target_id(id) do
    case parse_id(id) do
      {:ok, n} -> n
      :error -> nil
    end
  end

  defp load_dashboard(socket) do
    instances = InstanceStats.list_instances()
    delivery_counts = DeliveryStats.status_counts()
    failed_jobs = DeliveryStats.list_actionable_jobs(20)
    error_rate = DeliveryStats.error_rate_24h()
    boards = Content.list_all_boards()

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
