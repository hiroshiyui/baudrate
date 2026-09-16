defmodule BaudrateWeb.Admin.UserDetailLive do
  @moduledoc """
  Everything staff need to decide about one account, and the actions to act
  on that decision (ADR 0029).

  Before this, a moderator who had removed the same person's posts three times
  had nothing to look at and nothing to do about the person. The page gathers
  the record — role, status, sanction history, reports by and against the
  account, recent content, who invited them and whom they invited — and puts
  warn / silence / suspend / lift next to it.

  ## What a moderator may see

  Global moderators see the record above. **IP addresses and login attempts
  are admin-only**: they are personal data, and judging behaviour does not
  require them.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Auth
  alias Baudrate.Content
  alias Baudrate.Moderation
  alias Baudrate.Setup
  alias BaudrateWeb.RateLimits

  import BaudrateWeb.Helpers, only: [parse_id: 1, translate_role: 1, translate_status: 1]

  @kinds ~w(warn silence suspend)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case parse_id(id) do
      {:ok, user_id} -> mount_user(user_id, socket)
      :error -> {:ok, not_found(socket)}
    end
  end

  defp mount_user(user_id, socket) do
    case Auth.get_user(user_id) do
      nil ->
        {:ok, not_found(socket)}

      user ->
        {:ok,
         socket
         |> assign(:wide_layout, true)
         |> assign(:sanction_form, nil)
         |> assign(:page_title, gettext("User: %{username}", username: user.username))
         |> load(user)}
    end
  end

  defp not_found(socket) do
    socket
    |> put_flash(:error, gettext("User not found."))
    |> redirect(to: ~p"/admin/users")
  end

  # Everything the page shows is re-read after every action, so the record and
  # the buttons can never disagree about the account's current state.
  defp load(socket, user) do
    actor = socket.assigns.current_user
    admin? = permitted?(actor, "admin.manage_users")

    socket
    |> assign(:user, user)
    |> assign(:admin?, admin?)
    |> assign(:can_sanction?, Auth.authorize_sanction(actor, user, "silence") == :ok)
    |> assign(:max_expiry, Auth.max_sanction_expiry(actor))
    |> assign(:sanctions, Auth.list_sanctions(user))
    |> assign(:active_sanctions, Auth.active_sanctions(user))
    |> assign(:reports_about, Moderation.list_reports_about_user(user.id))
    |> assign(:reports_by, Moderation.list_reports_by_user(user.id))
    |> assign(:articles, Content.list_recent_articles_by_user(user.id, 10, viewer: actor))
    |> assign(:comments, Content.list_recent_comments_by_user(user.id, 10, viewer: actor))
    |> assign(:invitees, Auth.list_invitees(user.id))
    |> assign(:login_attempts, login_attempts(user, admin?))
  end

  # Admin-only, and not fetched at all otherwise: the cheapest way to keep
  # personal data off a page is not to put it in the socket.
  defp login_attempts(_user, false), do: []

  defp login_attempts(user, true) do
    Auth.paginate_login_attempts(username: user.username, per_page: 10).attempts
  end

  @impl true
  def handle_event("sanction_prompt", %{"kind" => kind}, socket) when kind in @kinds do
    {:noreply,
     assign(socket, :sanction_form, %{
       kind: kind,
       reason: "",
       days: default_days(kind, socket.assigns.max_expiry)
     })}
  end

  def handle_event("sanction_cancel", _params, socket) do
    {:noreply, socket |> assign(:sanction_form, nil) |> focus_heading()}
  end

  # LiveView patches every input back to the value the server rendered, so the
  # change handler has to keep what was typed.
  def handle_event("sanction_change", params, socket) do
    form = socket.assigns.sanction_form

    {:noreply,
     assign(socket, :sanction_form, %{
       form
       | reason: params["reason"] || form.reason,
         days: params["days"] || form.days
     })}
  end

  def handle_event("sanction_submit", params, socket) do
    %{current_user: actor, user: user, sanction_form: form} = socket.assigns
    reason = params["reason"] |> to_string() |> String.trim()
    days = params["days"] |> to_string() |> String.trim()

    opts =
      [reason: presence(reason), expires_at: expiry_from(days)]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    with :ok <- RateLimits.check_sanction(actor.id),
         {:ok, _sanction} <- Auth.issue_sanction(actor, user, form.kind, opts) do
      {:noreply,
       socket
       |> put_flash(:info, applied_message(form.kind))
       |> assign(:sanction_form, nil)
       |> load(Auth.get_user(user.id))
       |> focus_heading()}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, sanction_error(reason))}
    end
  end

  def handle_event("lift", %{"kind" => kind}, socket)
      when kind in ~w(silence suspend) do
    %{current_user: actor, user: user} = socket.assigns

    case Auth.lift_sanction(actor, user, kind) do
      {:ok, 0} ->
        {:noreply, put_flash(socket, :info, gettext("There was nothing to lift."))}

      {:ok, _count} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("The restriction was lifted."))
         |> load(Auth.get_user(user.id))
         |> focus_heading()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, sanction_error(reason))}
    end
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- display helpers used by the template ---

  @doc "Localized name of a sanction kind."
  def kind_label("warn"), do: gettext("Warning")
  def kind_label("silence"), do: gettext("Silence")
  def kind_label("suspend"), do: gettext("Suspension")
  def kind_label(other), do: other

  @doc """
  How a sanction stands right now: active, lifted, or simply over. Read from
  the clock, exactly as the gate reads it.
  """
  def sanction_state(%{lifted_at: at}) when not is_nil(at), do: :lifted
  def sanction_state(%{kind: "warn"}), do: :recorded
  def sanction_state(%{expires_at: nil}), do: :active

  def sanction_state(%{expires_at: at}) do
    if DateTime.compare(at, DateTime.utc_now()) == :gt, do: :active, else: :ended
  end

  @doc "Localized label for the state of a sanction."
  def state_label(:active), do: gettext("active")
  def state_label(:lifted), do: gettext("lifted")
  def state_label(:ended), do: gettext("ended")
  def state_label(:recorded), do: gettext("recorded")

  # --- internals ---

  defp default_days("warn", _max), do: ""
  defp default_days("suspend", _max), do: "3"
  defp default_days(_kind, nil), do: ""
  defp default_days(_kind, _max), do: "7"

  defp expiry_from(""), do: nil

  defp expiry_from(days) do
    case Integer.parse(days) do
      {n, ""} when n > 0 ->
        DateTime.utc_now()
        |> DateTime.add(n * 24 * 60 * 60, :second)
        |> DateTime.truncate(:second)

      _ ->
        nil
    end
  end

  defp applied_message("warn"), do: gettext("The member was warned.")
  defp applied_message("silence"), do: gettext("The account was silenced.")
  defp applied_message("suspend"), do: gettext("The account was suspended.")

  defp sanction_error(:self_action), do: gettext("You cannot do that to your own account.")
  defp sanction_error(:unauthorized), do: gettext("You cannot do that.")

  defp sanction_error(:role_too_high),
    do: gettext("You cannot act on an account at or above your own role.")

  defp sanction_error(:cannot_sanction_banned), do: gettext("That account is already banned.")

  defp sanction_error(:duration_too_long),
    do:
      gettext("Choose an end within %{days} days.",
        days: Baudrate.Auth.Sanctions.moderator_max_days()
      )

  defp sanction_error(:rate_limited), do: gettext("Too many actions. Try again shortly.")

  defp sanction_error(%Ecto.Changeset{} = changeset) do
    case changeset.errors do
      [{:expires_at, _} | _] -> gettext("A suspension needs an end date.")
      _ -> gettext("That did not work.")
    end
  end

  defp sanction_error(_), do: gettext("That did not work.")

  defp focus_heading(socket),
    do: push_event(socket, "focus", %{id: "admin-user-detail-heading"})

  defp permitted?(%{role: %{name: name}}, permission), do: Setup.has_permission?(name, permission)
  defp permitted?(_actor, _permission), do: false

  defp presence(""), do: nil
  defp presence(value), do: value
end
