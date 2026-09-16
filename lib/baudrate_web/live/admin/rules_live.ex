defmodule BaudrateWeb.Admin.RulesLive do
  @moduledoc """
  The site rules, as an ordered list an admin can edit (P1-D9).

  Rules are records rather than one markdown document so a report can cite the
  one it says was broken. That is the whole reason this page exists: the
  `rule_violation` report category could only ever say "breaks a rule", never
  which.

  Retiring, not deleting. A retired rule leaves `/rules` and the report dialog
  but still resolves for every report that already named it.
  """

  use BaudrateWeb, :live_view

  on_mount {BaudrateWeb.AuthHooks, :require_admin}

  alias Baudrate.Moderation
  alias Baudrate.Setup
  alias Baudrate.Setup.Rule

  import BaudrateWeb.Helpers, only: [parse_id: 1]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Site Rules"))
     |> assign(:editing_id, nil)
     |> assign(:new_form, blank_form())
     |> assign(:edit_form, nil)
     |> load_rules()}
  end

  @impl true
  def handle_event("validate_new", %{"rule" => params}, socket) do
    {:noreply, assign(socket, new_form: to_form(params, as: :rule))}
  end

  @impl true
  def handle_event("create", %{"rule" => params}, socket) do
    case Setup.create_rule(params) do
      {:ok, rule} ->
        log(socket, "create_rule", %{rule: rule.id, title: rule.title})

        {:noreply,
         socket
         |> put_flash(:info, gettext("Rule added."))
         |> assign(new_form: blank_form())
         |> load_rules()
         |> push_event("focus", %{id: "admin-rules-heading"})}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("That rule could not be saved."))
         |> assign(new_form: to_form(changeset, as: :rule))}
    end
  end

  @impl true
  def handle_event("start_edit", %{"id" => id}, socket) do
    with {:ok, rule_id} <- parse_id(id),
         %Rule{} = rule <- Setup.get_rule(rule_id) do
      {:noreply,
       socket
       |> assign(editing_id: rule.id, edit_form: to_form(Rule.changeset(rule, %{}), as: :rule))
       |> push_event("focus", %{id: "rule-title-#{rule.id}"})}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(editing_id: nil, edit_form: nil)
     |> push_event("focus", %{id: "admin-rules-heading"})}
  end

  @impl true
  def handle_event("validate_edit", %{"rule" => params}, socket) do
    {:noreply, assign(socket, edit_form: to_form(params, as: :rule))}
  end

  @impl true
  def handle_event("save_edit", %{"rule_id" => id, "rule" => params}, socket) do
    with {:ok, rule_id} <- parse_id(id),
         %Rule{} = rule <- Setup.get_rule(rule_id),
         {:ok, saved} <- Setup.update_rule(rule, params) do
      log(socket, "update_rule", %{rule: saved.id, title: saved.title})

      {:noreply,
       socket
       |> put_flash(:info, gettext("Rule saved."))
       |> assign(editing_id: nil, edit_form: nil)
       |> load_rules()
       |> push_event("focus", %{id: "admin-rules-heading"})}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, edit_form: to_form(changeset, as: :rule))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("That rule could not be saved."))}
    end
  end

  @impl true
  def handle_event("move", %{"id" => id, "direction" => direction}, socket)
      when direction in ["up", "down"] do
    with {:ok, rule_id} <- parse_id(id),
         %Rule{} = rule <- Setup.get_rule(rule_id),
         {:ok, moved} <- Setup.move_rule(rule, move_direction(direction)) do
      log(socket, "reorder_rules", %{rule: moved.id, direction: direction})

      {:noreply,
       socket
       |> load_rules()
       |> push_event("focus", %{id: "rule-move-#{moved.id}-#{direction}"})}
    else
      # Already at the top or bottom: nothing to say, the button simply does
      # not apply.
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("retire", %{"id" => id}, socket) do
    with {:ok, rule_id} <- parse_id(id),
         %Rule{} = rule <- Setup.get_rule(rule_id),
         {:ok, retired} <- Setup.retire_rule(rule) do
      log(socket, "retire_rule", %{rule: retired.id, title: retired.title})

      {:noreply,
       socket
       |> put_flash(
         :info,
         gettext("Rule retired. Reports that cite it still show which rule they meant.")
       )
       |> load_rules()
       |> push_event("focus", %{id: "admin-rules-heading"})}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("That rule could not be retired."))}
    end
  end

  @impl true
  def handle_event("restore", %{"id" => id}, socket) do
    with {:ok, rule_id} <- parse_id(id),
         %Rule{} = rule <- Setup.get_rule(rule_id),
         {:ok, restored} <- Setup.restore_rule(rule) do
      log(socket, "restore_rule", %{rule: restored.id, title: restored.title})

      {:noreply,
       socket
       |> put_flash(:info, gettext("Rule restored, at the end of the list."))
       |> load_rules()
       |> push_event("focus", %{id: "admin-rules-heading"})}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("That rule could not be restored."))}
    end
  end

  # An explicit map, never `String.to_existing_atom/1`: the guard above already
  # restricts the value, and a lookup keeps it that way if the guard moves.
  defp move_direction("up"), do: :up
  defp move_direction("down"), do: :down

  defp blank_form, do: to_form(%{"title" => "", "body" => ""}, as: :rule)

  defp load_rules(socket) do
    assign(socket, rules: Setup.list_rules(), retired: Setup.list_retired_rules())
  end

  defp log(socket, action, details) do
    Moderation.log_action(socket.assigns.current_user.id, action, details: details)
  end
end
