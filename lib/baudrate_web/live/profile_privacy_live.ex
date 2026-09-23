defmodule BaudrateWeb.ProfilePrivacyLive do
  @moduledoc """
  LiveView for a member's privacy settings (`/profile/privacy`): who may send
  them direct messages, whether follows wait for approval, whether they are
  discoverable, and what they have blocked or muted — accounts, whole
  servers, and words (ADR 0073).

  ## Muted servers and words

  A muted server hides that server's content from the member's own views
  (`Auth.mute_domain/2`); muted words collapse other people's posts behind
  "Hidden by your muted words" (`Auth.update_muted_keywords/2`). Both change
  nothing anyone else sees, and neither refuses an interaction. The add forms
  have no `phx-change`: nothing re-renders them while a member types.

  ## Blocked and Muted Accounts

  The Blocked Accounts and Muted Users sections list local users and remote
  actors, each with an undo control. Remote actors are stored by AP ID and
  shown as `@user@domain` when the actor is known (`@safety_remote_actors`).
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Auth
  alias BaudrateWeb.RateLimits

  import BaudrateWeb.ProfileComponents

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign_blocks_and_mutes(socket.assigns.current_user)
      |> assign(:muted_domains, Auth.list_muted_domains(socket.assigns.current_user))
      |> assign(:domain_form, to_form(%{"domain" => ""}, as: :domain_mute))
      |> assign(:word_form, to_form(%{"pattern" => "", "kind" => "word"}, as: :muted_word))
      |> assign(:privacy_status, "")
      |> assign(:page_title, gettext("Privacy"))

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_approval", _params, socket) do
    user = socket.assigns.current_user

    case Auth.update_manually_approves_followers(user, !user.manually_approves_followers) do
      {:ok, updated} ->
        message =
          if updated.manually_approves_followers,
            do: gettext("New followers now wait for your approval."),
            else: gettext("New followers no longer wait; any waiting requests were approved.")

        {:noreply, socket |> assign(:current_user, updated) |> put_flash(:info, message)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not change that setting."))}
    end
  end

  @impl true
  def handle_event("toggle_discoverable", _params, socket) do
    user = socket.assigns.current_user

    case Auth.update_discoverable(user, !user.discoverable) do
      {:ok, updated} ->
        message =
          if updated.discoverable,
            do: gettext("Search engines and the member search may list you again."),
            else:
              gettext(
                "Search engines are asked not to index you, and the member search leaves you out."
              )

        {:noreply, socket |> assign(:current_user, updated) |> put_flash(:info, message)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not change that setting."))}
    end
  end

  @impl true
  def handle_event("mute_domain", %{"domain_mute" => %{"domain" => domain} = params}, socket) do
    user = socket.assigns.current_user

    result =
      with :ok <- RateLimits.check_mute_user(user.id) do
        Auth.mute_domain(user, domain)
      end

    case result do
      {:ok, mute} ->
        {:noreply,
         socket
         |> assign(:muted_domains, Auth.list_muted_domains(user))
         |> assign(:domain_form, to_form(%{"domain" => ""}, as: :domain_mute))
         |> assign(:privacy_status, gettext("%{domain} muted.", domain: mute.domain))}

      {:error, :too_many} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("You can mute at most %{count} servers.", count: Auth.max_domain_mutes())
         )}

      {:error, :rate_limited} ->
        {:noreply,
         put_flash(socket, :error, gettext("Too many attempts. Please try again later."))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(
           socket,
           :domain_form,
           to_form(params, as: :domain_mute, errors: form_errors(changeset))
         )}
    end
  end

  @impl true
  def handle_event("unmute_domain", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with {int_id, ""} <- Integer.parse(to_string(id)) do
      Auth.unmute_domain(user, int_id)
    end

    {:noreply,
     socket
     |> assign(:muted_domains, Auth.list_muted_domains(user))
     |> assign(:privacy_status, gettext("Server unmuted."))
     |> push_event("focus", %{id: "profile-muted-domains-heading"})}
  end

  @impl true
  def handle_event("add_muted_word", %{"muted_word" => params}, socket) do
    user = socket.assigns.current_user
    entry = %{"kind" => params["kind"], "pattern" => params["pattern"] || ""}

    case Auth.update_muted_keywords(user, (user.muted_keywords || []) ++ [entry]) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign_muted_words(updated)
         |> assign(
           :word_form,
           to_form(%{"pattern" => "", "kind" => params["kind"] || "word"}, as: :muted_word)
         )
         |> assign(:privacy_status, gettext("Muted word added."))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:word_form, to_form(params, as: :muted_word, errors: form_errors(changeset)))
         |> put_flash(:error, muted_word_error(changeset))}
    end
  end

  @impl true
  def handle_event("remove_muted_word", %{"index" => index}, socket) do
    user = socket.assigns.current_user

    with {i, ""} <- Integer.parse(to_string(index)),
         {:ok, updated} <-
           Auth.update_muted_keywords(user, List.delete_at(user.muted_keywords || [], i)) do
      {:noreply,
       socket
       |> assign_muted_words(updated)
       |> assign(:privacy_status, gettext("Muted word removed."))
       |> push_event("focus", %{id: "profile-muted-words-heading"})}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("unmute", %{"id" => id}, socket) do
    user = socket.assigns.current_user
    mute = Enum.find(socket.assigns.mutes, &(to_string(&1.id) == id))

    if mute do
      if mute.muted_user_id do
        muted_user = Auth.get_user(mute.muted_user_id)
        if muted_user, do: Auth.unmute_user(user, muted_user)
      else
        Auth.unmute_remote_actor(user, mute.muted_actor_ap_id)
      end

      {:noreply,
       socket
       |> assign_blocks_and_mutes(user)
       |> put_flash(:info, gettext("User unmuted."))
       |> push_event("focus", %{id: "profile-muted-users-heading"})}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("unblock", %{"id" => id}, socket) do
    user = socket.assigns.current_user
    block = Enum.find(socket.assigns.blocks, &(to_string(&1.id) == id))

    if block do
      if block.blocked_user_id do
        blocked_user = Auth.get_user(block.blocked_user_id)
        if blocked_user, do: Auth.unblock_user(user, blocked_user)
      else
        Auth.unblock_remote_actor(user, block.blocked_actor_ap_id)
      end

      {:noreply,
       socket
       |> assign_blocks_and_mutes(user)
       |> put_flash(:info, gettext("Account unblocked."))
       |> push_event("focus", %{id: "profile-blocked-accounts-heading"})}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("update_dm_access", %{"dm_access" => value}, socket) do
    user = socket.assigns.current_user

    case Auth.update_dm_access(user, value) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(:current_user, updated_user)
         |> put_flash(:info, gettext("DM access setting updated."))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update DM access setting."))}
    end
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # Blocks and mutes of remote actors are stored by AP ID; the known actors are
  # looked up so the lists can show `@user@domain` instead of a bare URI.
  defp assign_blocks_and_mutes(socket, user) do
    blocks = Auth.list_blocks(user)
    mutes = Auth.list_mutes(user)

    remote_actors =
      (Enum.map(blocks, & &1.blocked_actor_ap_id) ++ Enum.map(mutes, & &1.muted_actor_ap_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Baudrate.Federation.remote_actors_by_ap_ids()

    assign(socket, blocks: blocks, mutes: mutes, safety_remote_actors: remote_actors)
  end

  attr :user, :any, default: nil
  attr :ap_id, :string, default: nil
  attr :remote_actors, :map, required: true
  attr :name_class, :string, required: true

  # One account in the blocked or muted list: a local user, a known remote
  # actor, or (for an actor this instance no longer knows) its AP ID.
  defp safety_list_account(assigns) do
    assigns =
      assign(assigns, :remote_actor, assigns.ap_id && assigns.remote_actors[assigns.ap_id])

    ~H"""
    <%= cond do %>
      <% @user -> %>
        <.avatar user={@user} size={36} />
        <span class={[@name_class, "font-semibold break-words min-w-0"]}>
          {display_name(@user)}
          <span class="text-sm font-normal text-base-content/70">@{@user.username}</span>
        </span>
      <% @remote_actor -> %>
        <div class="avatar avatar-placeholder">
          <div
            class="bg-neutral text-neutral-content rounded-full"
            style="width: 36px; height: 36px"
          >
            <span class="text-xs">@</span>
          </div>
        </div>
        <span class={[@name_class, "font-semibold break-words min-w-0"]}>
          {display_name(@remote_actor)}
          <span class="text-sm font-normal text-base-content/70 break-all">
            @{@remote_actor.username}@{@remote_actor.domain}
          </span>
        </span>
      <% true -> %>
        <div class="avatar avatar-placeholder">
          <div
            class="bg-neutral text-neutral-content rounded-full"
            style="width: 36px; height: 36px"
          >
            <span class="text-xs">@</span>
          </div>
        </div>
        <span class={[@name_class, "text-sm text-base-content/70 break-all min-w-0"]}>{@ap_id}</span>
    <% end %>
    """
  end

  defp safety_list_name(%Baudrate.Setup.User{username: username}, _ap_id, _actors), do: username

  defp safety_list_name(_user, ap_id, actors) do
    case actors[ap_id] do
      %{username: username, domain: domain} -> "@#{username}@#{domain}"
      nil -> ap_id
    end
  end

  # Keeps the assign `muted_collapse/1` reads in step with the saved list.
  defp assign_muted_words(socket, updated) do
    socket
    |> assign(:current_user, updated)
    |> assign(
      :muted_matchers,
      Enum.map(updated.muted_keywords || [], &Baudrate.Moderation.PatternMatcher.compile/1)
    )
  end

  defp form_errors(%Ecto.Changeset{errors: errors}),
    do: Enum.map(errors, fn {field, {msg, opts}} -> {field, {msg, opts}} end)

  defp muted_word_error(%Ecto.Changeset{errors: errors}) do
    case errors[:muted_keywords] do
      {"should have at most %{count} item(s)", _} ->
        gettext("You can keep at most %{count} muted words.",
          count: Baudrate.Setup.User.max_muted_keywords()
        )

      {"has no letters or numbers", _} ->
        gettext("A muted word needs a letter or a number.")

      {"with a * may hold only letters, numbers and *", _} ->
        gettext("Text with a * may hold only letters, numbers and *.")

      _ ->
        gettext("That muted word could not be added.")
    end
  end
end
