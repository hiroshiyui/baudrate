defmodule BaudrateWeb.Admin.DashboardLive do
  @moduledoc """
  `/admin`: the state of the site on one page (Phase 7A, ADR 0074).

  **Moderators** see what is waiting for them — open reports, posts held
  for review they could approve, and registrations waiting to be let in —
  because those are the queues they work. **Admins** also see the members,
  the federation figures and the health checks.

  The health checks come from `Baudrate.Health.report/1`, the same function
  behind the loopback report (ADR 0035), run after the page connects so a
  slow check never holds up the first render. The page shows each check's
  status and a few of its numbers under a translated name, never the
  report's English reason text, and it serves no report of its own: the
  loopback listener stays the only place the report is served whole.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.{Dashboard, Health}

  import BaudrateWeb.Helpers, only: [health_check_title: 1]

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    admin? = user.role.name == "admin"

    socket =
      socket
      |> assign(:page_title, gettext("Admin Dashboard"))
      |> assign(:admin?, admin?)
      |> assign(:moderation, Dashboard.moderation(user))
      |> assign(:members, if(admin?, do: Dashboard.members()))
      |> assign(:federation, if(admin?, do: Dashboard.federation()))

    socket =
      if admin? and connected?(socket),
        do: assign_async(socket, :health, fn -> {:ok, %{health: Health.report()}} end),
        else: assign(socket, :health, nil)

    {:ok, socket}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @doc false
  # The report's checks in its own order, skipping any it did not run.
  def health_rows(%{checks: checks}) do
    for name <- Health.check_names(), check = checks[name], do: {name, check}
  end

  @doc false
  # The numbers worth reading next to a check's status. Only counts and
  # sizes: the report's `reason` is English text for the operator's shell.
  # A failing check may carry no figures (the disk could not be read), so
  # each clause matches only the keys it reads.
  def check_facts(:delivery_queue, %{waiting: waiting, open_circuits: circuits}) do
    [
      gettext("%{count} waiting", count: waiting),
      ngettext("%{count} open circuit", "%{count} open circuits", circuits)
    ]
  end

  def check_facts(:inbound_queue, %{pending: pending}) do
    [gettext("%{count} waiting", count: pending)]
  end

  def check_facts(:disk, %{free_bytes: free, total_bytes: total}) do
    [gettext("%{free} GiB free of %{total} GiB", free: gib(free), total: gib(total))]
  end

  def check_facts(:backup, %{newest_age_seconds: age, count: count}) when is_integer(age) do
    hours = div(age, 3600)

    [
      ngettext("newest %{count} hour old", "newest %{count} hours old", hours),
      ngettext("%{count} kept", "%{count} kept", count)
    ]
  end

  def check_facts(_name, _result), do: []

  defp gib(bytes) when is_integer(bytes),
    do: :erlang.float_to_binary(bytes / (1024 * 1024 * 1024), decimals: 1)

  defp gib(_), do: "?"
end
