defmodule BaudrateWeb.ProfileNotificationsLive do
  @moduledoc """
  LiveView for a member's notification settings (`/profile/notifications`):
  browser push (`PushManagerHook`) and, per notification type, whether it
  appears on `/notifications` and whether it is pushed. `"direct_message"` is
  a push-only row (ADR 0071).
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Auth

  import BaudrateWeb.ProfileComponents

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    socket =
      socket
      |> assign(:notification_preferences, user.notification_preferences || %{})
      |> assign(:push_supported, false)
      |> assign(:push_subscribed, false)
      |> assign(:page_title, gettext("Notifications"))

    {:ok, socket}
  end

  @impl true
  def handle_event(
        "push_support",
        %{"supported" => supported, "subscribed" => subscribed},
        socket
      ) do
    {:noreply,
     socket
     |> assign(:push_supported, supported)
     |> assign(:push_subscribed, subscribed)}
  end

  @impl true
  def handle_event("push_subscribed", _params, socket) do
    {:noreply,
     socket
     |> assign(:push_subscribed, true)
     |> put_flash(:info, gettext("Push notifications enabled."))}
  end

  @impl true
  def handle_event("push_unsubscribed", _params, socket) do
    {:noreply,
     socket
     |> assign(:push_subscribed, false)
     |> put_flash(:info, gettext("Push notifications disabled."))}
  end

  @impl true
  def handle_event("push_permission_denied", _params, socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       gettext("Push notification permission was denied by the browser.")
     )}
  end

  @impl true
  def handle_event("push_subscribe_error", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("Failed to enable push notifications."))}
  end

  @impl true
  def handle_event("toggle_web_push_pref", %{"type" => type}, socket) do
    user = socket.assigns.current_user
    prefs = socket.assigns.notification_preferences

    type_prefs = Map.get(prefs, type, %{})
    current_web_push = Map.get(type_prefs, "web_push", true)
    new_type_prefs = Map.put(type_prefs, "web_push", !current_web_push)
    new_prefs = Map.put(prefs, type, new_type_prefs)

    case Auth.update_notification_preferences(user, new_prefs) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(:current_user, updated_user)
         |> assign(:notification_preferences, updated_user.notification_preferences)}

      {:error, _changeset} ->
        {:noreply,
         put_flash(socket, :error, gettext("Failed to update notification preferences."))}
    end
  end

  @impl true
  def handle_event("toggle_notification_pref", %{"type" => type}, socket) do
    user = socket.assigns.current_user
    prefs = socket.assigns.notification_preferences

    # Merged into the type's map, as `toggle_web_push_pref` does: replacing
    # the map threw away a stored web-push choice every time in-app changed.
    type_prefs = Map.get(prefs, type, %{})
    current_in_app = Map.get(type_prefs, "in_app") != false
    new_prefs = Map.put(prefs, type, Map.put(type_prefs, "in_app", !current_in_app))

    case Auth.update_notification_preferences(user, new_prefs) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(:current_user, updated_user)
         |> assign(:notification_preferences, updated_user.notification_preferences)}

      {:error, _changeset} ->
        {:noreply,
         put_flash(socket, :error, gettext("Failed to update notification preferences."))}
    end
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}
end
