defmodule BaudrateWeb.Admin.FiltersLive do
  @moduledoc """
  `/admin/filters` — words, text and linked domains that are refused, held
  for review or flagged (Phase 5D, ADR 0065). Admin-only.

  Every rule is `Baudrate.Moderation.ContentFilters`'s: this page creates,
  switches on and off, changes the action of, and deletes filters, and shows
  how often each one matched in the last 30 days. That count is the point of
  recording every match — a filter that fires a hundred times a day on posts
  nobody reported is probably catching the wrong thing, and this is where an
  admin finds out.

  The form takes a kind and a pattern, never a regular expression.
  """

  use BaudrateWeb, :live_view

  on_mount {BaudrateWeb.AuthHooks, :require_admin}

  alias Baudrate.Moderation.{ContentFilter, ContentFilters}

  import BaudrateWeb.Helpers, only: [parse_id: 1]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Content Filters"))
     |> assign(:wide_layout, true)
     |> assign(:form, blank_form())
     |> load_filters()}
  end

  @impl true
  def handle_event("validate", %{"filter" => params}, socket) do
    form =
      %ContentFilter{}
      |> ContentFilters.change_filter(params)
      |> Map.put(:action, :validate)
      |> to_form(as: :filter)

    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("create", %{"filter" => params}, socket) do
    case ContentFilters.create_filter(params, socket.assigns.current_user) do
      {:ok, filter} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Filter “%{pattern}” added.", pattern: filter.pattern))
         |> assign(:form, blank_form())
         |> load_filters()
         |> push_event("focus", %{id: "filters-pattern"})}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :filter))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("That filter could not be changed."))}
    end
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    with_filter(socket, id, gettext("Filter updated."), fn filter ->
      ContentFilters.update_filter(
        filter,
        %{enabled: !filter.enabled},
        socket.assigns.current_user
      )
    end)
  end

  def handle_event("set_action", %{"filter_id" => id, "filter_action" => action}, socket) do
    with_filter(socket, id, gettext("Filter updated."), fn filter ->
      ContentFilters.update_filter(filter, %{action: action}, socket.assigns.current_user)
    end)
  end

  def handle_event("delete", %{"id" => id}, socket) do
    {:noreply, socket} =
      with_filter(
        socket,
        id,
        gettext("Filter deleted."),
        &ContentFilters.delete_filter(&1, socket.assigns.current_user)
      )

    # The row that had focus is gone.
    {:noreply, push_event(socket, "focus", %{id: "filters-heading"})}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp with_filter(socket, id, message, fun) do
    with {:ok, filter_id} <- parse_id(id),
         %ContentFilter{} = filter <- ContentFilters.get_filter(filter_id),
         {:ok, _} <- fun.(filter) do
      {:noreply, socket |> put_flash(:info, message) |> load_filters()}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("That filter could not be changed."))}
    end
  end

  defp blank_form,
    do: to_form(ContentFilters.change_filter(%ContentFilter{}, %{}), as: :filter)

  defp load_filters(socket) do
    socket
    |> assign(:filters, ContentFilters.list_filters())
    |> assign(:match_counts, ContentFilters.recent_match_counts())
  end

  @doc false
  def kind_label("word"), do: gettext("Word or phrase")
  def kind_label("substring"), do: gettext("Text anywhere")
  def kind_label("domain"), do: gettext("Linked domain")
  def kind_label(other), do: other

  @doc false
  def action_label("block"), do: gettext("Refuse")
  def action_label("hold"), do: gettext("Hold for review")
  def action_label("flag"), do: gettext("Publish and report")
  def action_label(other), do: other

  @doc false
  def scope_label("local"), do: gettext("Posts written here")
  def scope_label("remote"), do: gettext("Content from other servers")
  def scope_label("both"), do: gettext("Both")
  def scope_label(other), do: other
end
