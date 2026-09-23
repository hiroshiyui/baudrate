defmodule BaudrateWeb.ProfileComponents do
  @moduledoc """
  The frame shared by a member's own settings pages: `/profile`,
  `/profile/security`, `/profile/notifications`, `/profile/privacy` and
  `/profile/account`.

  Each page is its own LiveView, so navigating between them remounts —
  which is also what drops the five-minute security unlock on
  `/profile/security`, exactly as a reload does.
  """

  use BaudrateWeb, :html

  @doc "The pages in navigation order: `{key, path, label}`."
  def pages do
    [
      {:profile, ~p"/profile", gettext("Profile")},
      {:security, ~p"/profile/security", gettext("Security")},
      {:notifications, ~p"/profile/notifications", gettext("Notifications")},
      {:privacy, ~p"/profile/privacy", gettext("Privacy")},
      {:account, ~p"/profile/account", gettext("Account")}
    ]
  end

  @doc """
  Renders a settings page: its navigation, its heading and its content.

  The navigation marks the current page with `aria-current="page"`.
  """
  attr :current, :atom, required: true
  attr :id, :string, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  def profile_page(assigns) do
    assigns = assign(assigns, :pages, pages())

    ~H"""
    <div id={@id} class="profile-page card bg-base-200 shadow-sm">
      <div class="card-body">
        <nav id="profile-nav" class="profile-nav mb-2" aria-label={gettext("Settings")}>
          <ul class="profile-nav-list flex flex-wrap gap-1">
            <li :for={{key, path, label} <- @pages} id={"profile-nav-item-#{key}"}>
              <.link
                id={"profile-nav-#{key}"}
                navigate={path}
                class={[
                  "profile-nav-link btn btn-sm",
                  if(key == @current, do: "btn-primary", else: "btn-ghost")
                ]}
                aria-current={if key == @current, do: "page"}
              >
                {label}
              </.link>
            </li>
          </ul>
        </nav>

        <h1 id="profile-heading" class="profile-page-heading card-title text-2xl mb-4">
          {@title}
        </h1>

        <div class="space-y-4">
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Explains the TOTP wait on the data export and account move pages: the date
  the member becomes eligible, in their own time zone, and why the rule
  exists (decision D4). Rendered inside the page's "not yet" alert.

  `offline` adds that the operator can prepare an export by hand
  (`Baudrate.Release.export_user_data/3`) — it does not say how to ask,
  because that differs per instance.
  """
  attr :id_prefix, :string, required: true
  attr :reason, :any, required: true
  attr :eligible_on, :any, default: nil
  attr :offline, :boolean, default: false

  def totp_wait_note(assigns) do
    assigns =
      assign(assigns,
        waiting: match?({:totp_too_new, _}, assigns.reason),
        explain: assigns.reason == :totp_required or match?({:totp_too_new, _}, assigns.reason)
      )

    ~H"""
    <p
      :if={@waiting && @eligible_on}
      id={"#{@id_prefix}-eligible-on"}
      class={"#{@id_prefix}-eligible-on"}
    >
      {gettext("Available from %{date}.", date: format_datetime(@eligible_on))}
    </p>
    <p :if={@explain} id={"#{@id_prefix}-totp-why"} class={"#{@id_prefix}-totp-why text-sm"}>
      {gettext(
        "Two-factor authentication has to have been on for a week, so that a stolen password alone is never enough to take everything in this account elsewhere."
      )}
    </p>
    <p
      :if={@explain && @offline}
      id={"#{@id_prefix}-offline"}
      class={"#{@id_prefix}-offline text-sm"}
    >
      {gettext("If you cannot wait, the operator of this site can prepare an export for you.")}
    </p>
    """
  end
end
