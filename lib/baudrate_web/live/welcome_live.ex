defmodule BaudrateWeb.WelcomeLive do
  @moduledoc """
  The first-visit step at `/welcome`, shown once to a newly registered member
  (P4-D2).

  Three things, in the order they matter:

    * **what a pending account can do**, in approval mode — the flash after
      registering used to be the only place this was said, and a flash is gone
      on the next page;
    * a display name and an avatar, so a new member is not a bare username in
      their first thread;
    * where to arrange recovery, which matters more here than on most forums:
      there is no email in this system, so recovery codes and an OpenPGP
      contact are the only ways back into an account
      ([ADR 0058](../../../doc/adr/0058-account-recovery-is-anchored-outside-the-instance.md)).

  **Skipping is a first-class outcome.** Both the save and the skip stamp
  `onboarded_at`, so this page is shown exactly once either way. A first-visit
  step that keeps coming back until it is filled in is the manufactured
  urgency ADR 0056 refuses, and a display name is the member's business.

  The avatar is centre-cropped rather than offering the crop modal `/profile`
  has: one decision fewer on a page whose job is to get out of the way, and
  `/profile` is where it can be redone properly.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Auth
  alias Baudrate.Avatar
  alias Baudrate.Setup.User
  alias BaudrateWeb.RateLimits

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if Auth.onboarded?(user) do
      {:ok, push_navigate(socket, to: ~p"/")}
    else
      {:ok,
       socket
       |> assign(:page_title, gettext("Welcome"))
       |> assign(:is_active, Auth.user_active?(user))
       |> assign(:form, display_name_form(user))
       |> allow_upload(:avatar,
         accept: ~w(.jpg .jpeg .png .webp),
         max_entries: 1,
         max_file_size: 5_000_000,
         auto_upload: true
       )}
    end
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    # The form re-renders on every keystroke, so it has to carry the typed
    # value back or LiveView patches the input to the stored one.
    changeset =
      socket.assigns.current_user
      |> User.display_name_changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset, as: :user))}
  end

  @impl true
  def handle_event("validate_avatar", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("save", %{"user" => params}, socket) do
    user = socket.assigns.current_user

    with {:ok, user} <- save_display_name(user, params),
         {:ok, user} <- save_avatar(socket, user) do
      finish(assign(socket, :current_user, user))
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :user))}

      {:error, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, message)}

      {:error, reason} ->
        # The interaction gate refuses a silenced, suspended or moved account
        # (ADR 0029), and a brand-new one can be silenced — or meet a terms
        # version published in the last minute — between registering and
        # reaching this page. Without this clause `update_display_name/2`'s
        # atom refusal fell out of the `with` and took the LiveView with it.
        # Every `{:error, reason}` catch-all routes through `refusal_message/3`
        # so the member is told what stands against them.
        {:noreply,
         put_flash(
           socket,
           :error,
           BaudrateWeb.Helpers.refusal_message(reason, user, gettext("Could not save that."))
         )}
    end
  end

  @impl true
  def handle_event("skip", _params, socket), do: finish(socket)

  # Ignore PubSub messages forwarded by the unread DM / notification count
  # hooks for a signed-in viewer.
  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp finish(socket) do
    {:ok, _user} = Auth.mark_onboarded(socket.assigns.current_user)
    {:noreply, push_navigate(socket, to: ~p"/")}
  end

  defp display_name_form(user) do
    user
    |> User.display_name_changeset(%{})
    |> to_form(as: :user)
  end

  defp save_display_name(user, %{"display_name" => name}) when is_binary(name) do
    case String.trim(name) do
      "" -> {:ok, user}
      trimmed -> Auth.update_display_name(user, trimmed)
    end
  end

  defp save_display_name(user, _params), do: {:ok, user}

  defp save_avatar(socket, user) do
    case uploaded_entries(socket, :avatar) do
      {[], _} ->
        {:ok, user}

      _ ->
        with :ok <- check_avatar_rate(user) do
          consume(socket, user)
        end
    end
  end

  defp check_avatar_rate(user) do
    case RateLimits.check_avatar_change(user.id) do
      :ok -> :ok
      {:error, :rate_limited} -> {:error, gettext("Too many avatar changes. Try again later.")}
    end
  end

  defp consume(socket, user) do
    consumed =
      consume_uploaded_entries(socket, :avatar, fn %{path: path}, _entry ->
        # No crop parameters: `Avatar.process_upload/2` centre-crops, which is
        # the right default for a step whose job is to get out of the way.
        {:ok, Avatar.process_upload(path, %{})}
      end)

    case consumed do
      [{:ok, avatar_id}] ->
        Avatar.delete_avatar(user.avatar_id)
        Auth.update_avatar(user, avatar_id)

      [{:error, :invalid_image}] ->
        {:error, gettext("Invalid image file.")}

      _ ->
        {:error, gettext("Failed to process avatar image.")}
    end
  end
end
