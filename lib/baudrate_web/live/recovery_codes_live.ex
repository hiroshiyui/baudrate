defmodule BaudrateWeb.RecoveryCodesLive do
  @moduledoc """
  LiveView for one-time display of recovery codes after TOTP enrollment.

  Recovery codes are read from the cookie session (placed there by
  `SessionController.totp_enable/2`) and displayed once. The user must
  acknowledge they've saved the codes, which POSTs to
  `SessionController.ack_recovery_codes/2` to clear them from the session.
  """

  use BaudrateWeb, :live_view

  @impl true
  def mount(_params, session, socket) do
    codes = session["recovery_codes"]

    if is_nil(codes) || codes == [] do
      {:ok, redirect(socket, to: "/")}
    else
      {:ok, assign(socket, codes: codes, page_title: gettext("Recovery Codes"))}
    end
  end
end
