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

  # Blocking is a moderation decision, so it goes through the form that asks
  # why (ADR 0030). The instance list prefills it rather than blocking outright.
  @impl true
  def handle_event("start_block", %{"domain" => domain}, socket) do
    {:noreply,
     socket
     |> assign(block_form: block_form(%{"domain" => domain}))
     |> push_event("focus", %{id: "domain-block-reason"})}
  end

  @impl true
  def handle_event("validate_block", %{"domain_block" => params}, socket) do
    {:noreply, assign(socket, block_form: block_form(params))}
  end

  @impl true
  def handle_event("block_domain", %{"domain_block" => params}, socket) do
    %{"domain" => domain, "reason" => reason} = params
    public_comment = Map.get(params, "public_comment", "")

    cond do
      String.trim(domain) == "" ->
        {:noreply, block_error(socket, params, gettext("Enter a domain to block."))}

      String.trim(reason) == "" ->
        {:noreply, block_error(socket, params, gettext("Say why this domain is being blocked."))}

      true ->
        do_block(socket, params, domain, reason, public_comment)
    end
  end

  @impl true
  def handle_event("start_unblock", %{"id" => id}, socket) do
    case parse_id(id) do
      :error ->
        {:noreply, socket}

      {:ok, block_id} ->
        {:noreply,
         socket
         |> assign(unblocking_id: block_id, unblock_reason: "")
         |> push_event("focus", %{id: "domain-unblock-reason-#{block_id}"})}
    end
  end

  @impl true
  def handle_event("cancel_unblock", _params, socket) do
    {:noreply,
     socket
     |> assign(unblocking_id: nil, unblock_reason: "")
     |> push_event("focus", %{id: "domain-blocks-heading"})}
  end

  @impl true
  def handle_event("validate_unblock", %{"reason" => reason}, socket) do
    {:noreply, assign(socket, unblock_reason: reason)}
  end

  @impl true
  def handle_event("unblock_domain", %{"block_id" => id, "reason" => reason}, socket) do
    with {:ok, block_id} <- parse_id(id),
         %{} = block <- Enum.find(socket.assigns.domain_blocks, &(&1.id == block_id)),
         {:ok, _} <- DomainBlocks.unblock_domain(block) do
      Moderation.log_action(socket.assigns.current_user.id, "unblock_domain",
        details: %{domain: block.domain, reason: String.trim(reason)}
      )

      {:noreply,
       socket
       |> put_flash(
         :info,
         gettext(
           "%{domain} is no longer blocked. Content from it is visible again.",
           domain: block.domain
         )
       )
       |> assign(unblocking_id: nil, unblock_reason: "")
       |> load_dashboard()
       |> push_event("focus", %{id: "domain-blocks-heading"})}
    else
      _ ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("That domain is no longer blocked."))
         |> assign(unblocking_id: nil, unblock_reason: "")
         |> load_dashboard()}
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
    case DomainBlocks.block_domain(domain, socket.assigns.current_user, audit_attrs()) do
      {:ok, block} ->
        Moderation.log_action(socket.assigns.current_user.id, "block_domain",
          details: %{domain: block.domain, reason: block.reason, source: "audit"}
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
         |> load_dashboard()
         |> assign(audit_result: result)
         |> push_event("focus", %{id: "blocklist-audit-heading"})}

      _ ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Domain %{domain} added to blocklist.", domain: domain))
         |> load_dashboard()
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
            case DomainBlocks.block_domain(domain, socket.assigns.current_user, audit_attrs()) do
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
             |> load_dashboard()
             |> assign(audit_result: result)
             |> push_event("focus", %{id: "blocklist-audit-heading"})}

          _ ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               gettext("Added %{count} domains to blocklist.", count: length(blocked))
             )
             |> load_dashboard()
             |> assign(audit_result: nil)
             |> push_event("focus", %{id: "blocklist-audit-heading"})}
        end

      _ ->
        {:noreply, socket}
    end
  end

  defp do_block(socket, params, domain, reason, public_comment) do
    case DomainBlocks.block_domain(domain, socket.assigns.current_user, %{
           reason: String.trim(reason),
           public_comment: String.trim(public_comment)
         }) do
      {:ok, block} ->
        Moderation.log_action(socket.assigns.current_user.id, "block_domain",
          details: %{domain: block.domain, reason: block.reason, source: "federation"}
        )

        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Domain %{domain} has been blocked.", domain: block.domain)
         )
         |> assign(block_form: block_form(%{}))
         |> load_dashboard()
         |> push_event("focus", %{id: "domain-blocks-heading"})}

      {:error, :already_blocked} ->
        {:noreply,
         block_error(
           socket,
           params,
           gettext("%{domain} is already blocked.", domain: String.trim(domain))
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, block_error(socket, params, changeset_message(changeset))}
    end
  end

  # A bulk import still records why the block exists, so a domain blocked by an
  # audit run is not indistinguishable from one an admin chose by hand.
  defp audit_attrs do
    %{reason: gettext("Imported from the external blocklist audit.")}
  end

  defp block_error(socket, params, message) do
    socket
    |> put_flash(:error, message)
    |> assign(block_form: block_form(params))
  end

  # The form is a plain map rather than a changeset: it collects three strings
  # and the context does the validating. Assigning the params back is what
  # keeps typed input from being wiped on re-render.
  defp block_form(params) do
    to_form(
      %{
        "domain" => Map.get(params, "domain", ""),
        "reason" => Map.get(params, "reason", ""),
        "public_comment" => Map.get(params, "public_comment", "")
      },
      as: :domain_block
    )
  end

  defp changeset_message(changeset) do
    case changeset.errors do
      [{field, {msg, _}} | _] ->
        gettext("%{field} %{message}", field: to_string(field), message: msg)

      _ ->
        gettext("That domain cannot be blocked.")
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
    domain_blocks = DomainBlocks.list_domain_blocks()
    blocked = MapSet.new(domain_blocks, & &1.domain)

    assign(socket,
      instances: instances,
      delivery_counts: delivery_counts,
      failed_jobs: failed_jobs,
      error_rate: error_rate,
      boards: boards,
      domain_blocks: domain_blocks,
      blocked_domains: blocked,
      block_form: socket.assigns[:block_form] || block_form(%{}),
      unblocking_id: socket.assigns[:unblocking_id],
      unblock_reason: socket.assigns[:unblock_reason] || "",
      audit_result: socket.assigns[:audit_result]
    )
  end
end
