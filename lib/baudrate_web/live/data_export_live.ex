defmodule BaudrateWeb.DataExportLive do
  @moduledoc """
  LiveView for self-service data export (`/profile/export`, ADR 0023).

  All authorization lives in `Baudrate.DataPortability`. This page only
  collects credentials and renders state.

  ## Flow

  1. **Eligibility.** The page explains why an account cannot export: TOTP
     missing or enrolled less than 7 days ago (with days left), a bot, or an
     inactive account.
  2. **Request.** Password plus current TOTP code (step-up, behind
     `RateLimits.check_reauth/1`). This creates a pending request that becomes
     downloadable after 24 hours.
  3. **Cancel.** Any session can cancel. "Cancel and sign out everywhere
     else" also re-authenticates, then revokes every other session.
  4. **Download.** Once ready, the user re-authenticates again. The page then
     issues a 60-second, single-use token bound to this session row and
     submits it to `ExportController` through `phx-trigger-action`, so no
     reusable download URL exists.

  The history table lists every request and cannot be edited.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.{Auth, DataPortability}
  alias Baudrate.DataPortability.DownloadNonces
  alias BaudrateWeb.{ExportController, RateLimits}

  import BaudrateWeb.Helpers, only: [extract_peer_ip: 1]

  @impl true
  def mount(_params, session, socket) do
    user_agent = if connected?(socket), do: get_connect_info(socket, :user_agent), else: nil

    socket =
      socket
      |> assign(:page_title, gettext("Export Your Data"))
      |> assign(:peer_ip, if(connected?(socket), do: extract_peer_ip(socket), else: "unknown"))
      |> assign(:user_agent, user_agent)
      |> assign(:session_id, Auth.session_id_by_token(session["session_token"]))
      |> assign(:download_token, nil)
      |> assign(:trigger_download, false)
      |> assign(:status_message, "")
      |> reset_forms()
      |> load_state()

    {:ok, socket}
  end

  @impl true
  def handle_event("request_export", %{"export_request" => params}, socket) do
    user = socket.assigns.current_user

    result =
      with :ok <- RateLimits.check_reauth(user.id) do
        DataPortability.request_export(user, credentials(params),
          ip_address: socket.assigns.peer_ip,
          session_id: socket.assigns.session_id,
          user_agent: socket.assigns.user_agent
        )
      end

    case result do
      {:ok, request} ->
        {:noreply,
         socket
         |> reset_forms()
         |> load_state()
         |> put_flash(
           :info,
           gettext("Data export requested. You can download it after %{time}.",
             time: format_datetime(request.ready_at)
           )
         )
         |> push_event("focus", %{id: "data-export-active-heading"})}

      {:error, reason} ->
        {:noreply, socket |> reset_forms() |> put_flash(:error, error_message(reason))}
    end
  end

  def handle_event("cancel_export", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with {request_id, ""} <- Integer.parse(to_string(id)),
         {:ok, _} <- DataPortability.cancel_export(user.id, request_id) do
      {:noreply,
       socket
       |> load_state()
       |> put_flash(:info, gettext("Data export request cancelled."))
       |> push_event("focus", %{id: "data-export-heading"})}
    else
      _ -> {:noreply, socket |> load_state() |> put_flash(:error, gettext("Request not found."))}
    end
  end

  def handle_event("cancel_and_sign_out", %{"cancel_sign_out" => params}, socket) do
    user = socket.assigns.current_user
    %{password: password, code: code} = credentials(params)

    result =
      with :ok <- RateLimits.check_reauth(user.id),
           :ok <-
             Auth.verify_reauthentication(
               user,
               password,
               code,
               socket.assigns.peer_ip,
               :data_export_cancel_sign_out
             ),
           session_id when is_integer(session_id) <-
             socket.assigns.session_id || {:error, :no_session} do
        # Signing out other sessions also cancels any active export request.
        Auth.sign_out_other_sessions(user, session_id)
      end

    case result do
      {:ok, revoked} ->
        {:noreply,
         socket
         |> reset_forms()
         |> load_state()
         |> put_flash(
           :info,
           ngettext(
             "Export cancelled and %{count} other session signed out. Consider changing your password.",
             "Export cancelled and %{count} other sessions signed out. Consider changing your password.",
             revoked,
             count: revoked
           )
         )
         |> push_event("focus", %{id: "data-export-heading"})}

      {:error, reason} ->
        {:noreply, socket |> reset_forms() |> put_flash(:error, error_message(reason))}
    end
  end

  def handle_event("authorize_download", %{"export_download" => params}, socket) do
    user = socket.assigns.current_user
    active = socket.assigns.active

    result =
      with %{id: request_id} <- active || {:error, :not_found},
           :ok <- RateLimits.check_reauth(user.id),
           {:ok, request} <-
             DataPortability.authorize_download(user, request_id, credentials(params),
               ip_address: socket.assigns.peer_ip
             ),
           session_id when is_integer(session_id) <-
             socket.assigns.session_id || {:error, :no_session} do
        {:ok, request, session_id}
      end

    case result do
      {:ok, request, session_id} ->
        token =
          Phoenix.Token.sign(BaudrateWeb.Endpoint, ExportController.token_salt(), %{
            "request_id" => request.id,
            "user_id" => user.id,
            "session_id" => session_id,
            "nonce" => DownloadNonces.issue(user.id)
          })

        # Clear the token from the page shortly after the form was submitted.
        Process.send_after(self(), :reset_download_trigger, 5_000)

        {:noreply,
         socket
         |> reset_forms()
         |> assign(:download_token, token)
         |> assign(:trigger_download, true)
         |> assign(
           :status_message,
           gettext("Preparing your data export. The download will start shortly.")
         )}

      {:error, reason} ->
        {:noreply, socket |> reset_forms() |> put_flash(:error, error_message(reason))}
    end
  end

  @impl true
  def handle_info(:reset_download_trigger, socket) do
    {:noreply,
     socket |> assign(:download_token, nil) |> assign(:trigger_download, false) |> load_state()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Password and (when enabled) TOTP fields for a step-up form. Ids are derived
  # from the form prefix, so the three forms on the page never collide.
  attr :prefix, :string, required: true
  attr :totp_enabled, :boolean, default: true

  defp export_credentials(assigns) do
    ~H"""
    <div class="form-control">
      <label
        id={"#{@prefix}-password-label"}
        class="data-export-field-label label"
        for={"#{@prefix}_password"}
      >
        <span class="label-text">{gettext("Password")}</span>
      </label>
      <input
        type="password"
        id={"#{@prefix}_password"}
        name={"#{@prefix}[password]"}
        class="data-export-password input input-bordered input-sm w-full max-w-xs"
        autocomplete="current-password"
        required
      />
    </div>
    <div :if={@totp_enabled} class="form-control">
      <label
        id={"#{@prefix}-code-label"}
        class="data-export-field-label label"
        for={"#{@prefix}_code"}
      >
        <span class="label-text">{gettext("Current TOTP Code")}</span>
      </label>
      <input
        type="text"
        id={"#{@prefix}_code"}
        name={"#{@prefix}[code]"}
        class="data-export-code input input-bordered input-sm w-full max-w-xs tracking-widest"
        inputmode="numeric"
        pattern="[0-9]{6}"
        maxlength="6"
        autocomplete="one-time-code"
        required
      />
    </div>
    """
  end

  defp load_state(socket) do
    user_id = socket.assigns.current_user.id
    fresh = Auth.get_user(user_id)

    socket
    |> assign(:eligibility, DataPortability.eligibility(fresh))
    |> assign(:totp_enabled, fresh.totp_enabled)
    |> assign(:active, DataPortability.active_request(user_id))
    |> assign(:history, DataPortability.list_export_history(user_id))
  end

  defp reset_forms(socket) do
    socket
    |> assign(:request_form, to_form(%{}, as: :export_request))
    |> assign(:download_form, to_form(%{}, as: :export_download))
    |> assign(:cancel_sign_out_form, to_form(%{}, as: :cancel_sign_out))
  end

  defp credentials(params) when is_map(params),
    do: %{password: params["password"], code: params["code"]}

  defp credentials(_), do: %{password: nil, code: nil}

  @doc false
  def error_message(:rate_limited), do: gettext("Too many attempts. Please try again later.")

  def error_message({:throttled, seconds}),
    do:
      gettext("Too many failed attempts. Please try again in %{seconds} seconds.",
        seconds: seconds
      )

  def error_message(:invalid_credentials), do: gettext("Invalid credentials. Please try again.")

  def error_message(:active_request_exists),
    do: gettext("You already have a data export request in progress.")

  def error_message(:weekly_limit_reached),
    do: gettext("You can request at most 2 data exports per week. Please try again later.")

  def error_message(:totp_required),
    do: gettext("Enable two-factor authentication (TOTP) to export your data.")

  def error_message({:totp_too_new, days}),
    do:
      ngettext(
        "Two-factor authentication must be enabled for 7 days first. You can export in %{count} day.",
        "Two-factor authentication must be enabled for 7 days first. You can export in %{count} days.",
        days,
        count: days
      )

  def error_message(:bot), do: gettext("Bot accounts cannot export data.")

  def error_message(:not_active),
    do: gettext("Only active accounts can export data. Please contact an administrator.")

  def error_message(:no_session),
    do: gettext("Your session has expired. Please sign in again.")

  def error_message(_), do: gettext("The data export is not available.")

  @doc false
  def status_label("pending"), do: gettext("Waiting")
  def status_label("ready"), do: gettext("Ready to download")
  def status_label("completed"), do: gettext("Completed")
  def status_label("cancelled"), do: gettext("Cancelled")
  def status_label("expired"), do: gettext("Expired")
  def status_label(other), do: other

  @doc false
  def cancel_reason_label("user"), do: gettext("by you")
  def cancel_reason_label("password_changed"), do: gettext("password changed")
  def cancel_reason_label("totp_changed"), do: gettext("two-factor authentication changed")
  def cancel_reason_label("banned"), do: gettext("account suspended")
  def cancel_reason_label("signed_out_everywhere"), do: gettext("signed out everywhere")
  def cancel_reason_label(_), do: nil
end
