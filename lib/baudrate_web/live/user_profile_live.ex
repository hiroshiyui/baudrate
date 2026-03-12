defmodule BaudrateWeb.UserProfileLive do
  @moduledoc """
  LiveView for public user profile pages.

  Displays a user's avatar, role, join date, content stats,
  recent articles & comments, and boosted articles & comments. Redirects if
  the user doesn't exist or is banned. Authenticated users can follow/unfollow
  and mute/unmute other users.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Auth
  alias Baudrate.Content
  alias Baudrate.Federation
  alias Baudrate.Moderation
  alias BaudrateWeb.LinkedData
  alias BaudrateWeb.OpenGraph
  alias BaudrateWeb.RateLimits
  import BaudrateWeb.Helpers, only: [translate_role: 1]

  @per_page 10

  @impl true
  def mount(%{"username" => username}, _session, socket) do
    case Auth.get_user_by_username(username) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("User not found."))
         |> redirect(to: ~p"/")}

      %{status: "banned"} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("User not found."))
         |> redirect(to: ~p"/")}

      user ->
        article_count = Content.count_articles_by_user(user.id)
        comment_count = Content.count_comments_by_user(user.id)
        current_user = socket.assigns.current_user

        is_muted =
          if current_user && current_user.id != user.id do
            Auth.muted?(current_user, user)
          else
            false
          end

        is_following =
          if current_user && current_user.id != user.id do
            Federation.local_follows?(current_user.id, user.id)
          else
            false
          end

        jsonld = LinkedData.user_jsonld(user) |> LinkedData.encode_jsonld()
        dc_meta = LinkedData.dublin_core_meta(:user, user)

        {:ok,
         socket
         |> assign(
           profile_user: user,
           article_count: article_count,
           comment_count: comment_count,
           is_muted: is_muted,
           is_following: is_following,
           page_title: user.username,
           linked_data_json: jsonld,
           dc_meta: dc_meta,
           og_meta: OpenGraph.user_tags(user, article_count, comment_count),
           show_report_modal: false,
           report_target_type: nil,
           report_target_id: nil,
           report_target_label: nil,
           activity_limit: @per_page,
           boosted_limit: @per_page
         )
         |> load_activity(user.id, @per_page)
         |> load_boosted(user.id, @per_page)}
    end
  end

  @impl true
  def handle_event("follow_user", _params, socket) do
    current_user = socket.assigns.current_user

    if current_user do
      case RateLimits.check_outbound_follow(current_user.id) do
        {:error, :rate_limited} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Follow rate limit exceeded. Please try again later.")
           )}

        :ok ->
          profile_user = socket.assigns.profile_user

          case Federation.create_local_follow(current_user, profile_user) do
            {:ok, _follow} ->
              {:noreply,
               socket
               |> assign(:is_following, true)
               |> put_flash(:info, gettext("Followed successfully."))}

            {:error, :self_follow} ->
              {:noreply, put_flash(socket, :error, gettext("You cannot follow yourself."))}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, gettext("Already following this user."))}
          end
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("unfollow_user", _params, socket) do
    current_user = socket.assigns.current_user

    if current_user do
      profile_user = socket.assigns.profile_user

      case Federation.delete_local_follow(current_user, profile_user) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(:is_following, false)
           |> put_flash(:info, gettext("Unfollowed successfully."))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not unfollow user."))}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("mute_user", _params, socket) do
    current_user = socket.assigns.current_user

    if current_user do
      case RateLimits.check_mute_user(current_user.id) do
        {:error, :rate_limited} ->
          {:noreply,
           put_flash(socket, :error, gettext("Too many actions. Please try again later."))}

        :ok ->
          profile_user = socket.assigns.profile_user

          case Auth.mute_user(current_user, profile_user) do
            {:ok, _} ->
              {:noreply,
               socket
               |> assign(:is_muted, true)
               |> put_flash(:info, gettext("User muted."))}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, gettext("Failed to mute user."))}
          end
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("unmute_user", _params, socket) do
    current_user = socket.assigns.current_user

    if current_user do
      profile_user = socket.assigns.profile_user

      Auth.unmute_user(current_user, profile_user)

      {:noreply,
       socket
       |> assign(:is_muted, false)
       |> put_flash(:info, gettext("User unmuted."))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("load_more_activity", _params, socket) do
    new_limit = socket.assigns.activity_limit + @per_page
    user_id = socket.assigns.profile_user.id

    {:noreply,
     socket
     |> assign(:activity_limit, new_limit)
     |> load_activity(user_id, new_limit)}
  end

  @impl true
  def handle_event("load_more_boosted", _params, socket) do
    new_limit = socket.assigns.boosted_limit + @per_page
    user_id = socket.assigns.profile_user.id

    {:noreply,
     socket
     |> assign(:boosted_limit, new_limit)
     |> load_boosted(user_id, new_limit)}
  end

  @impl true
  def handle_event("open_report_modal", %{"type" => type, "id" => id} = params, socket) do
    label = params["label"]

    {:noreply,
     socket
     |> assign(:show_report_modal, true)
     |> assign(:report_target_type, type)
     |> assign(:report_target_id, id)
     |> assign(:report_target_label, label)}
  end

  @impl true
  def handle_event("close_report_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_report_modal, false)
     |> assign(:report_target_type, nil)
     |> assign(:report_target_id, nil)
     |> assign(:report_target_label, nil)}
  end

  @impl true
  def handle_event("submit_report", %{"reason" => reason}, socket) do
    user = socket.assigns.current_user
    profile_user = socket.assigns.profile_user

    case RateLimits.check_create_report(user.id) do
      {:error, :rate_limited} ->
        {:noreply,
         socket
         |> assign(:show_report_modal, false)
         |> put_flash(:error, gettext("Too many reports. Please try again later."))}

      :ok ->
        target_attrs = %{reported_user_id: profile_user.id}

        if Moderation.has_open_report?(user.id, target_attrs) do
          {:noreply,
           socket
           |> assign(:show_report_modal, false)
           |> put_flash(:error, gettext("You have already reported this."))}
        else
          attrs = Map.merge(target_attrs, %{reason: reason, reporter_id: user.id})

          case Moderation.create_report(attrs) do
            {:ok, _report} ->
              {:noreply,
               socket
               |> assign(:show_report_modal, false)
               |> put_flash(:info, gettext("Report submitted. Thank you."))}

            {:error, _changeset} ->
              {:noreply, put_flash(socket, :error, gettext("Failed to submit report."))}
          end
        end
    end
  end

  defp load_activity(socket, user_id, limit) do
    results = Content.list_recent_activity_by_user(user_id, limit + 1)
    has_more = length(results) > limit

    assign(socket,
      recent_activity: Enum.take(results, limit),
      has_more_activity: has_more
    )
  end

  defp load_boosted(socket, user_id, limit) do
    results = Content.list_recent_boosted_by_user(user_id, limit + 1)
    has_more = length(results) > limit

    assign(socket,
      boosted_activity: Enum.take(results, limit),
      has_more_boosted: has_more
    )
  end

  defp digest(nil), do: ""

  defp digest(text) do
    plain =
      text
      |> Baudrate.Sanitizer.Native.strip_tags()
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    if String.length(plain) > 200 do
      String.slice(plain, 0, 200) <> "…"
    else
      plain
    end
  end
end
