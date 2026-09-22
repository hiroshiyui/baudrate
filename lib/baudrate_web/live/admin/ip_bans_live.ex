defmodule BaudrateWeb.Admin.IpBansLive do
  @moduledoc """
  `/admin/ip-bans` — refuse registration and sign-in from an address or range
  (Phase 5E). Admin-only, like the login-attempt log beside it that most bans
  start from.

  Every decision lives in `Baudrate.Auth.IpBans`; this page only renders its
  answers. In particular the refusals — a private range, too broad a range, a
  range holding the admin's own address — are the context's, and the page
  passes the admin's address in rather than deciding anything about it.

  A broad range needs a second tick, and the page shows how many addresses the
  typed range covers before it is submitted, because the difference between a
  `/24` and a `/16` is 256 people or 65 536 and nothing in the notation makes
  that obvious.
  """

  use BaudrateWeb, :live_view

  on_mount {BaudrateWeb.AuthHooks, :require_admin}

  alias Baudrate.Auth
  alias Baudrate.Auth.{IpBan, IpBans}

  import BaudrateWeb.Helpers, only: [parse_id: 1, extract_peer_ip: 1]

  @impl true
  def mount(_params, _session, socket) do
    peer_ip = if connected?(socket), do: extract_peer_ip(socket), else: nil

    {:ok,
     socket
     |> assign(:page_title, gettext("IP Bans"))
     |> assign(:wide_layout, true)
     |> assign(:peer_ip, peer_ip)
     |> assign(:form_params, blank_form())
     |> assign(:preview, nil)
     |> load_bans()}
  end

  # "Ban this address" on the login-attempt log links here with `?address=`,
  # so the form arrives filled in and nothing is banned until it is submitted.
  @impl true
  def handle_params(params, _uri, socket) do
    case params["address"] do
      address when is_binary(address) and address != "" ->
        form = %{blank_form() | "address" => address}
        {:noreply, socket |> assign(:form_params, form) |> assign(:preview, preview(address))}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("change", %{"ban" => params}, socket) do
    params = Map.merge(blank_form(), params)

    {:noreply,
     socket |> assign(:form_params, params) |> assign(:preview, preview(params["address"]))}
  end

  def handle_event("create", %{"ban" => params}, socket) do
    params = Map.merge(blank_form(), params)

    attrs = %{
      "reason" => blank_to_nil(params["reason"]),
      "expires_at" => expires_at(params["expires_days"])
    }

    case Auth.ban_ip(params["address"], attrs, socket.assigns.current_user,
           actor_ip: socket.assigns.peer_ip,
           confirm_broad: params["confirm_broad"] == "true"
         ) do
      {:ok, ban} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("%{range} is banned.", range: IpBan.to_cidr(ban)))
         |> assign(:form_params, blank_form())
         |> assign(:preview, nil)
         |> load_bans()
         |> push_event("focus", %{id: "ip-bans-address"})}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("That range is already banned, or the reason is too long.")
         )}

      {:error, reason} ->
        {:noreply, socket |> assign(:form_params, params) |> put_flash(:error, refusal(reason))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with {:ok, ban_id} <- parse_id(id),
         :ok <- Auth.unban_ip(ban_id, socket.assigns.current_user) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("The ban was lifted."))
       |> load_bans()
       # The row that had focus is gone; put it somewhere a keyboard user can
       # continue from.
       |> push_event("focus", %{id: "ip-bans-heading"})}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("That ban could not be lifted."))}
    end
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- helpers ---

  defp load_bans(socket) do
    now = DateTime.utc_now()

    bans =
      Enum.map(IpBans.list(), fn ban ->
        %{ban: ban, cidr: IpBan.to_cidr(ban), active: IpBans.active?(ban, now)}
      end)

    assign(socket, :bans, bans)
  end

  defp blank_form do
    %{"address" => "", "reason" => "", "expires_days" => "", "confirm_broad" => "false"}
  end

  # How many addresses the typed range covers, and whether it will need the
  # second tick — shown before submitting rather than discovered after.
  defp preview(address) do
    case IpBan.parse(address || "") do
      {:ok, parsed} ->
        %{
          cidr: IpBan.to_cidr(parsed),
          size: IpBan.size(parsed),
          broad: parsed.prefix_length < Map.fetch!(IpBans.confirm_below(), parsed.family)
        }

      :error ->
        nil
    end
  end

  defp expires_at(days) do
    case Integer.parse(String.trim(days || "")) do
      {n, ""} when n > 0 and n <= 3650 ->
        DateTime.utc_now() |> DateTime.add(n * 86_400, :second) |> DateTime.truncate(:second)

      _ ->
        nil
    end
  end

  defp blank_to_nil(value) do
    case String.trim(value || "") do
      "" -> nil
      v -> v
    end
  end

  @doc false
  def refusal(:invalid_address),
    do:
      gettext(
        "That is not an address or a range. Enter an address such as 1.2.3.4, or a range such as 1.2.3.0/24."
      )

  def refusal(:private_range),
    do:
      gettext(
        "That is a private or loopback range. It is what every visitor looks like when the reverse proxy is misconfigured, so banning it would ban everyone."
      )

  def refusal(:too_broad), do: gettext("That range is too broad to ban.")

  def refusal(:needs_confirmation),
    do: gettext("That is a broad range. Tick the confirmation below if you mean it.")

  def refusal(:own_address),
    do:
      gettext(
        "That range contains the address you are using now, so banning it would lock you out of this page."
      )

  def refusal(:unauthorized), do: gettext("You are not allowed to ban addresses.")
end
