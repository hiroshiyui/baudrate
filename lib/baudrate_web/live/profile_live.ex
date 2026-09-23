defmodule BaudrateWeb.ProfileLive do
  @moduledoc """
  LiveView for the member's public profile settings (`/profile`): avatar,
  display name, bio, profile fields and signature — what other people see.

  The rest of a member's settings live on sibling pages sharing
  `BaudrateWeb.ProfileComponents.profile_page/1`: `/profile/security`,
  `/profile/notifications`, `/profile/privacy` and `/profile/account`.

  ## Profile Fields

  Users can set up to 4 custom key-value fields (e.g. website, location).
  These are published as `attachment` entries of type `PropertyValue` on the
  ActivityPub actor, matching the Mastodon convention for profile metadata.
  The `@profile_fields` assign is always a list of exactly 4 maps (padded
  with empty entries) for predictable template rendering.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Auth
  alias Baudrate.Avatar
  alias BaudrateWeb.RateLimits

  import BaudrateWeb.ProfileComponents
  import BaudrateWeb.Helpers, only: [translate_role: 1]

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    socket =
      socket
      |> assign(:is_active, Auth.user_active?(user))
      |> assign(:can_upload_avatar, Auth.can_upload_avatar?(user))
      |> assign(:show_crop_modal, false)
      |> assign(
        :display_name_form,
        to_form(Baudrate.Setup.User.display_name_changeset(user, %{}), as: :display_name)
      )
      |> assign(:bio_form, to_form(Baudrate.Setup.User.bio_changeset(user, %{}), as: :bio))
      |> assign(
        :signature_form,
        to_form(Baudrate.Setup.User.signature_changeset(user, %{}), as: :signature)
      )
      |> assign(:signature_preview, Baudrate.Content.Markdown.to_html(user.signature))
      |> assign(:profile_fields, pad_profile_fields(user.profile_fields))
      |> assign(:page_title, gettext("Profile"))
      |> allow_upload(:avatar,
        accept: ~w(.jpg .jpeg .png .webp),
        max_entries: 1,
        max_file_size: 5_000_000,
        auto_upload: true
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_avatar", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("show_crop_modal", _params, socket) do
    {:noreply, assign(socket, :show_crop_modal, true)}
  end

  @impl true
  def handle_event("cancel_crop", _params, socket) do
    socket =
      socket
      |> assign(:show_crop_modal, false)
      |> push_event("avatar_crop_reset", %{})

    {:noreply, cancel_all_uploads(socket, :avatar)}
  end

  @impl true
  def handle_event("save_crop", crop_params, socket) do
    user = socket.assigns.current_user

    case RateLimits.check_avatar_change(user.id) do
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

  @impl true
  def handle_event("validate_display_name", %{"display_name" => params}, socket) do
    user = socket.assigns.current_user

    changeset =
      Baudrate.Setup.User.display_name_changeset(user, params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :display_name_form, to_form(changeset, as: :display_name))}
  end

  @impl true
  def handle_event(
        "save_display_name",
        %{"display_name" => %{"display_name" => display_name}},
        socket
      ) do
    user = socket.assigns.current_user

    case Auth.update_display_name(user, display_name) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(:current_user, updated_user)
         |> put_flash(:info, gettext("Display name updated."))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :display_name_form, to_form(changeset, as: :display_name))}

      {:error, reason} ->
        {:noreply, refuse(socket, reason, gettext("Failed to update display name."))}
    end
  end

  @impl true
  def handle_event("validate_bio", %{"bio" => params}, socket) do
    user = socket.assigns.current_user

    changeset =
      Baudrate.Setup.User.bio_changeset(user, params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :bio_form, to_form(changeset, as: :bio))}
  end

  @impl true
  def handle_event("save_bio", %{"bio" => %{"bio" => bio}}, socket) do
    user = socket.assigns.current_user

    case Auth.update_bio(user, bio) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(:current_user, updated_user)
         |> put_flash(:info, gettext("Bio updated."))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :bio_form, to_form(changeset, as: :bio))}

      {:error, reason} ->
        {:noreply, refuse(socket, reason, gettext("Failed to update bio."))}
    end
  end

  @impl true
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

  @impl true
  def handle_event("save_signature", %{"signature" => %{"signature" => signature}}, socket) do
    user = socket.assigns.current_user

    case Auth.update_signature(user, signature) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(:current_user, updated_user)
         |> assign(:signature_preview, Baudrate.Content.Markdown.to_html(updated_user.signature))
         |> put_flash(:info, gettext("Signature updated."))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :signature_form, to_form(changeset, as: :signature))}

      {:error, reason} ->
        {:noreply, refuse(socket, reason, gettext("Failed to update signature."))}
    end
  end

  @impl true
  def handle_event("save_profile_fields", params, socket) do
    user = socket.assigns.current_user
    raw = Map.get(params, "profile_fields", %{})
    fields = parse_raw_profile_fields(raw)

    case Auth.update_profile_fields(user, fields) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(:current_user, updated_user)
         |> assign(:profile_fields, pad_profile_fields(updated_user.profile_fields))
         |> put_flash(:info, gettext("Profile fields updated."))}

      {:error, reason} ->
        {:noreply, refuse(socket, reason, gettext("Failed to update profile fields."))}
    end
  end

  @impl true
  def handle_event("remove_avatar", _params, socket) do
    user = socket.assigns.current_user

    case RateLimits.check_avatar_change(user.id) do
      :ok ->
        # The files go only once the account no longer points at them: a
        # refused removal (a silenced member, ADR 0029) must leave the avatar
        # it still shows intact.
        case Auth.remove_avatar(user) do
          {:ok, updated_user} ->
            Avatar.delete_avatar(user.avatar_id)

            socket =
              socket
              |> assign(:current_user, updated_user)
              |> put_flash(:info, gettext("Avatar removed."))

            {:noreply, socket}

          {:error, reason} ->
            {:noreply, refuse(socket, reason, gettext("Failed to remove avatar."))}
        end

      {:error, :rate_limited} ->
        {:noreply,
         put_flash(socket, :error, gettext("Too many avatar changes. Please try again later."))}
    end
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

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
        # The old files go only once the account points at the new ones; on a
        # refusal the new ones go instead, and the avatar shown is untouched.
        case Auth.update_avatar(user, avatar_id) do
          {:ok, updated_user} ->
            Avatar.delete_avatar(user.avatar_id)

            socket =
              socket
              |> assign(:current_user, updated_user)
              |> assign(:show_crop_modal, false)
              |> push_event("avatar_crop_reset", %{})
              |> put_flash(:info, gettext("Avatar updated successfully."))

            {:noreply, socket}

          {:error, reason} ->
            Avatar.delete_avatar(avatar_id)
            {:noreply, refuse(socket, reason, gettext("Failed to update avatar."))}
        end

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

  defp upload_error_to_string(err), do: BaudrateWeb.Helpers.upload_error_to_string(err)

  defp pad_profile_fields(nil), do: List.duplicate(%{"name" => "", "value" => ""}, 4)

  defp pad_profile_fields(fields) when is_list(fields) do
    empty = %{"name" => "", "value" => ""}
    padded = fields ++ List.duplicate(empty, 4)
    Enum.take(padded, 4)
  end

  defp parse_raw_profile_fields(raw) when is_map(raw) do
    raw
    |> Enum.sort_by(fn {k, _} -> String.to_integer(k) end)
    |> Enum.map(fn {_, field} ->
      name = Map.get(field, "name", "") |> String.trim()
      value = Map.get(field, "value", "") |> String.trim()
      %{"name" => name, "value" => value}
    end)
    |> Enum.reject(fn %{"name" => name} -> name == "" end)
  end

  defp parse_raw_profile_fields(_), do: []

  # A refusal from a gate says what stands against the member and until when
  # (ADR 0029) or what a new account must wait for (ADR 0064); anything else
  # keeps the handler's own message. Every `{:error, reason}` catch-all here
  # goes through it — they used to hand the reason to `to_form/2`, which
  # crashed the page for a silenced member saving their bio.
  defp refuse(socket, reason, fallback) do
    put_flash(
      socket,
      :error,
      BaudrateWeb.Helpers.refusal_message(reason, socket.assigns.current_user, fallback)
    )
  end
end
