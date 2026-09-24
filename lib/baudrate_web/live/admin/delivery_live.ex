defmodule BaudrateWeb.Admin.DeliveryLive do
  @moduledoc """
  The outgoing delivery queue, for admins (Phase 7E):
  `/admin/federation/delivery`.

  Lists every job that can still be acted on — `pending` and `failed` —
  a page at a time, filtered by the job's exact `domain`, with retry and
  abandon for one job or for every job of the filtered domain, and the
  domains whose circuit is open (ADR 0034) with a way to close one after
  fixing a problem on our side.

  Abandoning a domain's jobs and closing a circuit are recorded in the
  moderation log: the first drops activities that will never be sent, the
  second overrides the breaker. Retrying is not — it only moves a job
  earlier in a queue it was already in.
  """

  use BaudrateWeb, :live_view

  on_mount {BaudrateWeb.AuthHooks, :require_admin}

  alias Baudrate.Federation.{DeliveryCircuits, DeliveryStats}
  alias Baudrate.Moderation

  import BaudrateWeb.Helpers,
    only: [parse_id: 1, parse_page: 1, translate_delivery_status: 1]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       wide_layout: true,
       domain: nil,
       page_title: gettext("Admin Delivery Queue")
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign(:domain, DeliveryStats.normalize_domain(params["domain"]))
      |> assign(:requested_page, parse_page(params["page"]))
      |> load()

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter", %{"domain" => domain}, socket) do
    {:noreply, push_patch(socket, to: path(DeliveryStats.normalize_domain(domain)))}
  end

  def handle_event("retry_job", %{"id" => id}, socket) do
    with {:ok, job_id} <- parse_id(id),
         {:ok, _job} <- DeliveryStats.retry_job(job_id) do
      {:noreply, done(socket, gettext("Job queued for retry."))}
    else
      _ -> {:noreply, socket |> put_flash(:error, gettext("Job not found.")) |> load()}
    end
  end

  def handle_event("abandon_job", %{"id" => id}, socket) do
    with {:ok, job_id} <- parse_id(id),
         {:ok, _job} <- DeliveryStats.abandon_job(job_id) do
      {:noreply, done(socket, gettext("Job abandoned."))}
    else
      _ -> {:noreply, socket |> put_flash(:error, gettext("Job not found.")) |> load()}
    end
  end

  # The bulk actions act on the domain the page is filtered by — the one the
  # admin is looking at — never on a value the event carries.
  def handle_event("retry_domain", _params, %{assigns: %{domain: domain}} = socket)
      when is_binary(domain) do
    {count, _} = DeliveryStats.retry_all_failed_for_domain(domain)

    {:noreply,
     done(
       socket,
       ngettext(
         "%{count} failed job for %{domain} queued for retry.",
         "%{count} failed jobs for %{domain} queued for retry.",
         count,
         domain: domain
       )
     )}
  end

  def handle_event("abandon_domain", _params, %{assigns: %{domain: domain}} = socket)
      when is_binary(domain) do
    {count, _} = DeliveryStats.abandon_all_for_domain(domain)

    if count > 0 do
      Moderation.log_action(socket.assigns.current_user.id, "abandon_deliveries",
        details: %{"domain" => domain, "count" => count}
      )
    end

    {:noreply,
     done(
       socket,
       ngettext(
         "%{count} job for %{domain} abandoned.",
         "%{count} jobs for %{domain} abandoned.",
         count,
         domain: domain
       )
     )}
  end

  def handle_event("close_circuit", %{"domain" => domain}, socket) do
    case DeliveryCircuits.close(domain) do
      {:ok, circuit} ->
        Moderation.log_action(socket.assigns.current_user.id, "close_delivery_circuit",
          details: %{"domain" => circuit.domain, "trips" => circuit.trips}
        )

        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Circuit for %{domain} closed; its jobs will be sent on the next pass.",
             domain: circuit.domain
           )
         )
         |> load()
         |> push_event("focus", %{id: "admin-delivery-circuits-heading"})}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("That circuit is no longer open."))
         |> load()}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp done(socket, message) do
    socket
    |> put_flash(:info, message)
    |> load()
    |> push_event("focus", %{id: "admin-delivery-jobs-heading"})
  end

  defp load(socket) do
    domain = socket.assigns.domain
    opts = [page: socket.assigns[:requested_page] || 1, domain: domain]

    %{jobs: jobs, page: page, total_pages: total_pages, total: total} =
      DeliveryStats.paginate_actionable_jobs(opts)

    assign(socket,
      jobs: jobs,
      page: page,
      total_pages: total_pages,
      total: total,
      counts: DeliveryStats.status_counts(),
      error_rate: DeliveryStats.error_rate_24h(),
      waiting_domains: waiting_domains(domain),
      circuits: DeliveryCircuits.list_tripped(),
      now: DateTime.utc_now()
    )
  end

  # The filtered domain stays selectable even once its last job is gone, so
  # the select never silently shows a different value from the page.
  defp waiting_domains(domain) do
    domains = DeliveryStats.waiting_domains()

    if is_binary(domain) and not List.keymember?(domains, domain, 0),
      do: domains ++ [{domain, 0}],
      else: domains
  end

  defp path(nil), do: ~p"/admin/federation/delivery"
  defp path(domain), do: ~p"/admin/federation/delivery?#{%{domain: domain}}"
end
