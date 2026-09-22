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
  require them. So are recovery contacts, and for the same reason plus one
  more: they are the anchor a reset rests on.

  ## Account recovery (ADR 0058)

  Two actions, deliberately separate. **Verifying a contact** confirms that a
  signed message from that address checked out against the key the member
  registered — the check happens in the admin's own mail client, and
  `doc/sysop.md` is the procedure. **Issuing a reset** hands over a link,
  shown once, and only against a contact that is already verified.

  Neither creates an anchor: there is no control here that puts an address or
  a key on somebody else's account. An admin confirms what a member
  registered, and the member registered it from their own signed-in session.
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
         # Shown once, straight after issuing. Never read back from anywhere:
         # only the hash of the token is stored.
         |> assign(:issued_reset_token, nil)
         |> assign(:clear_second_factors, false)
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
    |> assign_new(:chain_ban, fn -> nil end)
    |> assign(:login_attempts, login_attempts(user, admin?))
    |> assign(:recovery_contacts, recovery_contacts(user, admin?))
    |> assign(:live_reset, Auth.live_account_reset(user))
    |> assign(:last_reset, admin? && Auth.last_account_reset(user))
    |> assign(:can_reset?, admin? and Auth.can_issue_account_reset?(actor, user))
  end

  # Admin-only. A recovery contact is personal data and the anchor a reset
  # rests on, so a moderator never sees one.
  defp recovery_contacts(_user, false), do: []
  defp recovery_contacts(user, true), do: Auth.list_recovery_contacts(user)

  # Each state reads as a sentence, because an admin scanning this page is
  # asking "did they use it?" and a bare status word does not answer that.
  defp reset_summary(reset) do
    who = (reset.issued_by && reset.issued_by.username) || gettext("an admin")

    case Auth.account_reset_state(reset) do
      :outstanding ->
        gettext("A reset link issued by %{admin} is outstanding until %{expires}.",
          admin: who,
          expires: format_datetime(reset.expires_at)
        )

      :used ->
        gettext("A reset link issued by %{admin} was used on %{used}.",
          admin: who,
          used: format_datetime(reset.used_at)
        )

      :revoked ->
        gettext("A reset link issued by %{admin} was revoked and never used.", admin: who)

      :expired ->
        gettext("A reset link issued by %{admin} expired unused on %{expires}.",
          admin: who,
          expires: format_datetime(reset.expires_at)
        )
    end
  end

  defp verification_flash("verified"),
    do: gettext("Recovery contact verified. It can now be used to issue a reset link.")

  defp verification_flash("pending"),
    do: gettext("Recovery contact set back to unverified.")

  # Each refusal says which rule refused, because an admin acting on a
  # recovery request needs to know whether to look for a different contact or
  # to stop entirely.
  defp reset_refusal(:no_verified_contact),
    do:
      gettext(
        "This account has no verified recovery contact, so there is no proof of identity to act on."
      )

  defp reset_refusal(:role_too_high),
    do:
      gettext(
        "You cannot reset an account at or above your own role. Recovering one needs the server console."
      )

  defp reset_refusal(:self_action),
    do: gettext("Use your own recovery codes rather than issuing yourself a link.")

  defp reset_refusal(:unauthorized), do: gettext("You are not allowed to do that.")
  defp reset_refusal(_other), do: gettext("Could not issue a reset link.")

  # Admin-only, and not fetched at all otherwise: the cheapest way to keep
  # personal data off a page is not to put it in the socket.
  defp login_attempts(_user, false), do: []

  defp login_attempts(user, true) do
    Auth.paginate_login_attempts(username: user.username, per_page: 10).attempts
  end

  @impl true
  def handle_event("verify_contact", %{"id" => id, "status" => status}, socket)
      when status in ["verified", "pending"] do
    with {:ok, contact_id} <- parse_id(id),
         {:ok, _contact} <-
           Auth.set_recovery_contact_verification(socket.assigns.current_user, contact_id, status) do
      {:noreply,
       socket
       |> load(Auth.get_user(socket.assigns.user.id))
       |> put_flash(:info, verification_flash(status))}
    else
      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not update that contact."))}
    end
  end

  @impl true
  def handle_event("toggle_clear_second_factors", _params, socket) do
    {:noreply, assign(socket, :clear_second_factors, !socket.assigns.clear_second_factors)}
  end

  @impl true
  def handle_event("issue_reset", %{"contact_id" => id}, socket) do
    actor = socket.assigns.current_user
    user = socket.assigns.user

    with {:ok, contact_id} <- parse_id(id),
         {:ok, token, _reset} <-
           Auth.issue_account_reset(actor, user, contact_id,
             clear_second_factors: socket.assigns.clear_second_factors
           ) do
      {:noreply,
       socket
       |> assign(:issued_reset_token, token)
       |> assign(:clear_second_factors, false)
       |> load(Auth.get_user(user.id))
       |> put_flash(
         :info,
         gettext("Link issued. Copy it now — it is not shown again, and it works once.")
       )}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reset_refusal(reason))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not issue a reset link."))}
    end
  end

  @impl true
  def handle_event("revoke_reset", _params, socket) do
    case Auth.revoke_account_reset(socket.assigns.current_user, socket.assigns.user) do
      {:ok, _count} ->
        {:noreply,
         socket
         |> assign(:issued_reset_token, nil)
         |> load(Auth.get_user(socket.assigns.user.id))
         |> put_flash(:info, gettext("Reset link revoked."))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reset_refusal(reason))}
    end
  end

  @impl true
  def handle_event("dismiss_reset_token", _params, socket) do
    {:noreply, assign(socket, :issued_reset_token, nil)}
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

  # --- Ban with invitees (Phase 5A) ---
  #
  # The whole chain is shown and nothing is ticked: the point of showing it is
  # that somebody looked at every account before it was banned, because a
  # spammer's invitee is sometimes a real member.

  def handle_event("chain_ban_open", _params, socket) do
    tree = Auth.invite_tree(socket.assigns.user.id)
    {:noreply, assign(socket, :chain_ban, %{tree: tree, selected: MapSet.new(), reason: ""})}
  end

  def handle_event("chain_ban_cancel", _params, socket) do
    {:noreply, socket |> assign(:chain_ban, nil) |> focus_heading()}
  end

  # The checkboxes and the reason are one form, and every change is assigned
  # back — otherwise ticking a box re-renders the form and erases the reason
  # being typed (the LiveView input-reset trap in CLAUDE.md).
  def handle_event("chain_ban_change", params, socket) do
    {:noreply, update_chain_ban(socket, params)}
  end

  def handle_event("chain_ban_all", _params, socket) do
    %{chain_ban: cb, user: user} = socket.assigns
    ids = [user.id | Enum.map(cb.tree.nodes, & &1.user.id)]
    {:noreply, assign(socket, :chain_ban, %{cb | selected: MapSet.new(ids)})}
  end

  def handle_event("chain_ban_none", _params, socket) do
    {:noreply, update(socket, :chain_ban, &%{&1 | selected: MapSet.new()})}
  end

  def handle_event("chain_ban_submit", params, socket) do
    socket = update_chain_ban(socket, params)
    %{chain_ban: cb, user: user, current_user: actor} = socket.assigns
    reason = if String.trim(cb.reason) == "", do: nil, else: String.trim(cb.reason)

    if MapSet.size(cb.selected) == 0 do
      {:noreply, put_flash(socket, :error, gettext("Select at least one account to ban."))}
    else
      # The context intersects this selection with a tree it computes itself,
      # so an id edited into the page cannot reach an account outside it.
      {:ok, %{banned: banned, refused: refused}} =
        Auth.ban_invite_chain(user, MapSet.to_list(cb.selected), actor, reason)

      {:noreply,
       socket
       |> assign(:chain_ban, nil)
       |> put_flash(chain_ban_flash_kind(refused), chain_ban_flash(banned, refused))
       |> load(Auth.get_user(user.id))
       |> focus_heading()}
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

  defp update_chain_ban(%{assigns: %{chain_ban: nil}} = socket, _params), do: socket

  defp update_chain_ban(socket, params) do
    selected =
      params
      |> Map.get("selected", [])
      |> List.wrap()
      |> Enum.flat_map(fn id ->
        case parse_id(id) do
          {:ok, n} -> [n]
          :error -> []
        end
      end)
      |> MapSet.new()

    update(socket, :chain_ban, &%{&1 | selected: selected, reason: params["reason"] || &1.reason})
  end

  defp chain_ban_flash_kind([]), do: :info
  defp chain_ban_flash_kind(_refused), do: :error

  defp chain_ban_flash(banned, []) do
    ngettext("%{count} account banned.", "%{count} accounts banned.", length(banned))
  end

  # A refusal is almost always the rank rule: an admin's invitee who is also
  # staff. Name them, so the moderator knows the chain is not fully closed.
  defp chain_ban_flash(banned, refused) do
    gettext("%{banned} banned. Not banned, because you may not ban them: %{refused}.",
      banned: length(banned),
      refused: refused |> Enum.map(fn {u, _why} -> u.username end) |> Enum.join(", ")
    )
  end
end
