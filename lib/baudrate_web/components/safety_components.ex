defmodule BaudrateWeb.SafetyComponents do
  @moduledoc """
  Menu items for the controls members use to protect themselves from a remote
  account: mute, block and report. Rendered inside the existing "More
  actions" dropdowns on timeline items, remote comments and remote conversations;
  the events are handled with `BaudrateWeb.SafetyActions`.
  """

  use BaudrateWeb, :html

  @doc """
  Renders the `<li>` items for a remote actor.

  Blocking and muting hide the actor's content, so timeline items and comments
  disappear afterwards and only need the "add" controls. A conversation stays
  on screen, so it passes `muted`/`blocked` to get the undo controls.
  """
  attr :actor, :map, required: true
  attr :id_prefix, :string, required: true
  attr :muted, :boolean, default: false
  attr :blocked, :boolean, default: false

  def remote_actor_safety_items(assigns) do
    assigns = assign(assigns, :handle, "@#{assigns.actor.username}@#{assigns.actor.domain}")

    ~H"""
    <li :if={!@muted}>
      <button
        type="button"
        id={"#{@id_prefix}-mute-actor"}
        class="remote-actor-mute"
        phx-click="mute_remote_actor"
        phx-value-id={@actor.id}
        data-confirm={
          gettext("Mute %{handle}? Their content will be hidden from you.", handle: @handle)
        }
        aria-label={gettext("Mute %{handle}", handle: @handle)}
      >
        <.icon name="hero-speaker-x-mark" class="size-4" />
        {gettext("Mute account")}
      </button>
    </li>
    <li :if={@muted}>
      <button
        type="button"
        id={"#{@id_prefix}-unmute-actor"}
        class="remote-actor-unmute"
        phx-click="unmute_remote_actor"
        phx-value-id={@actor.id}
        aria-label={gettext("Unmute %{handle}", handle: @handle)}
      >
        <.icon name="hero-speaker-wave" class="size-4" />
        {gettext("Unmute account")}
      </button>
    </li>
    <li :if={!@blocked}>
      <button
        type="button"
        id={"#{@id_prefix}-block-actor"}
        class="remote-actor-block text-error"
        phx-click="block_remote_actor"
        phx-value-id={@actor.id}
        data-confirm={
          gettext(
            "Block %{handle}? You will stop following each other, and neither of you can reply to, like, boost, follow or message the other.",
            handle: @handle
          )
        }
        aria-label={gettext("Block %{handle}", handle: @handle)}
      >
        <.icon name="hero-no-symbol" class="size-4" />
        {gettext("Block account")}
      </button>
    </li>
    <li :if={@blocked}>
      <button
        type="button"
        id={"#{@id_prefix}-unblock-actor"}
        class="remote-actor-unblock"
        phx-click="unblock_remote_actor"
        phx-value-id={@actor.id}
        aria-label={gettext("Unblock %{handle}", handle: @handle)}
      >
        <.icon name="hero-check-circle" class="size-4" />
        {gettext("Unblock account")}
      </button>
    </li>
    <li>
      <button
        type="button"
        id={"#{@id_prefix}-report-actor"}
        class="remote-actor-report"
        phx-click="open_report_modal"
        phx-value-type="remote_actor"
        phx-value-id={@actor.id}
        phx-value-label={@handle}
        aria-label={gettext("Report %{handle}", handle: @handle)}
      >
        <.icon name="hero-flag" class="size-4" />
        {gettext("Report account")}
      </button>
    </li>
    """
  end
end
