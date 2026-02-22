defmodule BaudrateWeb.ProfileLive do
  @moduledoc """
  LiveView for the user profile page (`/profile`).

  Displays read-only account details, avatar management, and locale preferences
  for the current user. `@current_user` is available via the `:require_auth` hook.

  ## Locale Preferences

  Users can add, remove, and reorder preferred locales. Changes are persisted
  to the database and take effect immediately via `Gettext.put_locale/1`.
  The locale is also stored in the cookie session on next login.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Auth
  alias Baudrate.Avatar
  alias BaudrateWeb.Locale

  @max_avatar_changes_per_hour 5

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    policy = Auth.totp_policy(user.role.name)
    is_active = Auth.user_active?(user)

    signature_changeset = Baudrate.Setup.User.signature_changeset(user, %{})

    socket =
      socket
      |> assign(:totp_policy, policy)
      |> assign(:is_active, is_active)
      |> assign(:show_crop_modal, false)
      |> assign(:preferred_locales, user.preferred_locales || [])
      |> assign(:available_locales, Locale.available_locales())
      |> assign(:signature_form, to_form(signature_changeset, as: :signature))
      |> assign(:signature_preview, Baudrate.Content.Markdown.to_html(user.signature))
      |> assign(:page_title, gettext("Profile"))
      |> allow_upload(:avatar,
        accept: ~w(.jpg .jpeg .png .webp),
        max_entries: 1,
        max_file_size: 5_000_000
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_avatar", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("show_crop_modal", _params, socket) do
    {:noreply, assign(socket, :show_crop_modal, true)}
  end

  def handle_event("cancel_crop", _params, socket) do
    socket =
      socket
      |> assign(:show_crop_modal, false)
      |> push_event("avatar_crop_reset", %{})

    {:noreply, cancel_all_uploads(socket, :avatar)}
  end

  def handle_event("save_crop", crop_params, socket) do
    user = socket.assigns.current_user

    case check_rate_limit(user.id) do
      :ok ->
        process_and_save_avatar(socket, user, crop_params)

      {:error, :rate_limited} ->
        socket =
          socket
          |> put_flash(:error, gettext("Too many avatar changes. Please try again later."))
          |> assign(:show_crop_modal, false)
          |> push_event("avatar_crop_reset", %{})

        {:noreply, cancel_all_uploads(socket, :avatar)}
    end
  end

  def handle_event("add_locale", %{"locale" => locale}, socket) do
    current = socket.assigns.preferred_locales

    if locale in current do
      {:noreply, socket}
    else
      save_locales(socket, current ++ [locale])
    end
  end

  def handle_event("remove_locale", %{"locale" => locale}, socket) do
    new_locales = Enum.reject(socket.assigns.preferred_locales, &(&1 == locale))
    save_locales(socket, new_locales)
  end

  def handle_event("move_locale_up", %{"locale" => locale}, socket) do
    locales = socket.assigns.preferred_locales
    idx = Enum.find_index(locales, &(&1 == locale))

    if idx && idx > 0 do
      new_locales = swap(locales, idx, idx - 1)
      save_locales(socket, new_locales)
    else
      {:noreply, socket}
    end
  end

  def handle_event("move_locale_down", %{"locale" => locale}, socket) do
    locales = socket.assigns.preferred_locales
    idx = Enum.find_index(locales, &(&1 == locale))

    if idx && idx < length(locales) - 1 do
      new_locales = swap(locales, idx, idx + 1)
      save_locales(socket, new_locales)
    else
      {:noreply, socket}
    end
  end

  def handle_event("validate_signature", %{"signature" => params}, socket) do
    user = socket.assigns.current_user

    changeset =
      Baudrate.Setup.User.signature_changeset(user, params)
      |> Map.put(:action, :validate)

    preview = Baudrate.Content.Markdown.to_html(params["signature"] || "")

    {:noreply,
     socket
     |> assign(:signature_form, to_form(changeset, as: :signature))
     |> assign(:signature_preview, preview)}
  end

  def handle_event("save_signature", %{"signature" => %{"signature" => signature}}, socket) do
    user = socket.assigns.current_user

    case Auth.update_signature(user, signature) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(:current_user, updated_user)
         |> assign(:signature_preview, Baudrate.Content.Markdown.to_html(updated_user.signature))
         |> put_flash(:info, gettext("Signature updated."))}

      {:error, changeset} ->
        {:noreply, assign(socket, :signature_form, to_form(changeset, as: :signature))}
    end
  end

  def handle_event("remove_avatar", _params, socket) do
    user = socket.assigns.current_user

    case check_rate_limit(user.id) do
      :ok ->
        Avatar.delete_avatar(user.avatar_id)
        {:ok, updated_user} = Auth.remove_avatar(user)

        socket =
          socket
          |> assign(:current_user, updated_user)
          |> put_flash(:info, gettext("Avatar removed."))

        {:noreply, socket}

      {:error, :rate_limited} ->
        {:noreply,
         put_flash(socket, :error, gettext("Too many avatar changes. Please try again later."))}
    end
  end

  defp process_and_save_avatar(socket, user, crop_params) do
    consumed =
      consume_uploaded_entries(socket, :avatar, fn %{path: path}, _entry ->
        case Avatar.process_upload(path, crop_params) do
          {:ok, avatar_id} -> {:ok, {:ok, avatar_id}}
          {:error, reason} -> {:ok, {:error, reason}}
        end
      end)

    case consumed do
      [{:ok, avatar_id}] ->
        # Delete old avatar files if they exist
        Avatar.delete_avatar(user.avatar_id)

        {:ok, updated_user} = Auth.update_avatar(user, avatar_id)

        socket =
          socket
          |> assign(:current_user, updated_user)
          |> assign(:show_crop_modal, false)
          |> push_event("avatar_crop_reset", %{})
          |> put_flash(:info, gettext("Avatar updated successfully."))

        {:noreply, socket}

      [{:error, :invalid_image}] ->
        socket =
          socket
          |> assign(:show_crop_modal, false)
          |> push_event("avatar_crop_reset", %{})
          |> put_flash(:error, gettext("Invalid image file."))

        {:noreply, socket}

      [{:error, _reason}] ->
        socket =
          socket
          |> assign(:show_crop_modal, false)
          |> push_event("avatar_crop_reset", %{})
          |> put_flash(:error, gettext("Failed to process avatar image."))

        {:noreply, socket}

      [] ->
        {:noreply, socket}
    end
  end

  defp cancel_all_uploads(socket, upload_name) do
    Enum.reduce(socket.assigns.uploads[upload_name].entries, socket, fn entry, acc ->
      cancel_upload(acc, upload_name, entry.ref)
    end)
  end

  defp upload_error_to_string(:too_large), do: gettext("Image file is too large.")
  defp upload_error_to_string(:not_accepted), do: gettext("Invalid image file.")
  defp upload_error_to_string(:too_many_files), do: gettext("Too many files.")
  defp upload_error_to_string(_), do: gettext("Upload error.")

  defp check_rate_limit(user_id) do
    case Hammer.check_rate("avatar_change:#{user_id}", 3_600_000, @max_avatar_changes_per_hour) do
      {:allow, _count} -> :ok
      {:deny, _limit} -> {:error, :rate_limited}
    end
  end

  defp save_locales(socket, new_locales) do
    user = socket.assigns.current_user

    case Auth.update_preferred_locales(user, new_locales) do
      {:ok, updated_user} ->
        locale =
          case Locale.resolve_from_preferences(new_locales) do
            nil -> Gettext.get_locale()
            l -> l
          end

        Gettext.put_locale(locale)

        socket =
          socket
          |> assign(:current_user, updated_user)
          |> assign(:preferred_locales, updated_user.preferred_locales)
          |> assign(:locale, locale)
          |> put_flash(:info, gettext("Language preferences updated."))

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update language preferences."))}
    end
  end

  defp swap(list, i, j) do
    list
    |> List.replace_at(i, Enum.at(list, j))
    |> List.replace_at(j, Enum.at(list, i))
  end
end
