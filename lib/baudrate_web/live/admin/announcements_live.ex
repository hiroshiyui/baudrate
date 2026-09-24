defmodule BaudrateWeb.Admin.AnnouncementsLive do
  @moduledoc """
  `/admin/announcements` (Phase 7B): post a notice every page shows, and
  end one early.

  An announcement runs for a chosen number of days or until it is ended, and
  can also be sent as a notification to every member. Ended announcements
  stay listed as the record of what was said. Creating and ending one are
  recorded in the moderation log. The rules live in `Baudrate.Announcements`.
  """

  use BaudrateWeb, :live_view

  on_mount {BaudrateWeb.AuthHooks, :require_admin}

  alias Baudrate.Announcements
  alias Baudrate.Announcements.Announcement
  alias Baudrate.Moderation

  import BaudrateWeb.Helpers, only: [parse_id: 1]

  @durations ~w(1 3 7 30 none)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Admin Announcements"))
     |> assign(:max_body, Announcement.max_body())
     |> assign(:form, blank_form())
     |> load()}
  end

  @impl true
  def handle_event("validate", %{"announcement" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: :announcement))}
  end

  def handle_event("create", %{"announcement" => params}, socket) do
    admin = socket.assigns.current_user
    attrs = %{"body" => params["body"] || "", "ends_at" => ends_at(params["duration"])}
    notify? = params["notify"] == "true"

    case Announcements.create_announcement(admin, attrs, notify: notify?) do
      {:ok, announcement} ->
        Moderation.log_action(admin.id, "create_announcement",
          target_type: "announcement",
          target_id: announcement.id,
          details: %{"notified" => notify?}
        )

        {:noreply,
         socket
         |> put_flash(
           :info,
           if(notify?,
             do: gettext("Announcement posted and sent to members."),
             else: gettext("Announcement posted.")
           )
         )
         |> assign(:form, blank_form())
         |> load()
         |> push_event("focus", %{id: "admin-announcements-list-heading"})}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("An announcement needs text, at most %{max} characters.",
             max: Announcement.max_body()
           )
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("You cannot do that."))}
    end
  end

  def handle_event("end", %{"id" => id}, socket) do
    admin = socket.assigns.current_user

    with {:ok, id} <- parse_id(id),
         {:ok, announcement} <- Announcements.end_announcement(admin, id) do
      Moderation.log_action(admin.id, "end_announcement",
        target_type: "announcement",
        target_id: announcement.id
      )

      {:noreply,
       socket
       |> put_flash(:info, gettext("Announcement ended."))
       |> load()
       |> push_event("focus", %{id: "admin-announcements-list-heading"})}
    else
      _ ->
        {:noreply,
         socket |> put_flash(:error, gettext("That announcement has already ended.")) |> load()}
    end
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @doc false
  def durations, do: @durations

  @doc false
  def duration_label("1"), do: gettext("1 day")
  def duration_label("3"), do: gettext("3 days")
  def duration_label("7"), do: gettext("7 days")
  def duration_label("30"), do: gettext("30 days")
  def duration_label("none"), do: gettext("Until I end it")

  # Only the offered durations: anything else is treated as "no end",
  # which an admin can still end by hand.
  defp ends_at(days) when days in ~w(1 3 7 30) do
    DateTime.utc_now(:second) |> DateTime.add(String.to_integer(days), :day)
  end

  defp ends_at(_), do: nil

  defp blank_form,
    do: to_form(%{"body" => "", "duration" => "7", "notify" => "false"}, as: :announcement)

  defp load(socket) do
    socket
    |> assign(:announcements, Announcements.list_announcements())
    |> assign(:now, DateTime.utc_now())
  end
end
