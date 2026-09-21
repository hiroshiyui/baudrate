defmodule BaudrateWeb.RecoveryNoticeHook do
  @moduledoc """
  LiveView `attach_hook` that handles `"dismiss_recovery_notice"` events.

  The recovery notice is rendered by the layout, so its dismiss button can fire
  on any authenticated page. A `handle_event` that can arrive anywhere belongs
  in a shared hook rather than in each LiveView — the same rule
  `AutocompleteSuggestHook` and `MarkdownPreviewHook` follow, and for the same
  reason: a page without the clause crashes with a `FunctionClauseError` for
  anyone who happens to click it there.

  **Dismissal is remembered, not re-asked.** A notice that comes back after
  being dismissed is the manufactured urgency
  [ADR 0056](../../../doc/adr/0056-boring-but-friendly.md) refuses, and a
  member may have deliberate reasons for arranging recovery their own way. The
  notice exists because with no email in this system an account with no codes
  and no verified contact cannot be recovered at all
  ([ADR 0058](../../../doc/adr/0058-account-recovery-is-anchored-outside-the-instance.md))
  — which is safety work, and decision 5 of 0056 is explicit that boring is
  never an argument against that.

  Attach this hook in `on_mount` callbacks via `attach(socket)`.
  """

  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3]

  alias Baudrate.Auth

  @doc """
  Attaches the `:recovery_notice` handle_event hook to the socket.

  Returns the socket unchanged if the lifecycle system is not initialized
  (e.g. in unit tests with bare `%Socket{}`).
  """
  def attach(%{private: %{lifecycle: _}} = socket) do
    attach_hook(socket, :recovery_notice, :handle_event, &handle_event/3)
  end

  def attach(socket), do: socket

  defp handle_event("dismiss_recovery_notice", _params, socket) do
    case socket.assigns[:current_user] do
      nil ->
        {:halt, socket}

      user ->
        {:ok, updated} = Auth.dismiss_recovery_notice(user)

        {:halt,
         socket
         |> assign(:current_user, updated)
         |> assign(:recovery_pending, false)}
    end
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}
end
