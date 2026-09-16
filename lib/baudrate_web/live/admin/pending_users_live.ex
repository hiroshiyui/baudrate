defmodule BaudrateWeb.Admin.PendingUsersLive do
  @moduledoc """
  The queue of registrations waiting to be let in.

  The two acts are authorized separately (ADR 0029). **Approving** is an admin
  decision (`admin.manage_users`): letting someone into a public hub is not
  moderation. **Refusing** needs only `moderator.sanction_user`, so a global
  moderator can turn away obvious spam registrations without waiting for an
  admin — which is also why the page is open to moderators at all.

  A refusal is a ban with a reason on an account that is still `pending`,
  recorded as `reject_user`; there is no separate `rejected` status for the
  codebase's `status != "banned"` checks to forget.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Auth
  alias Baudrate.Moderation
  alias Baudrate.Setup
  alias BaudrateWeb.RateLimits

  import BaudrateWeb.Helpers, only: [parse_id: 1]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:pending_users, Auth.list_pending_users())
     |> assign(:can_approve?, permitted?(socket, "admin.manage_users"))
     |> assign(:can_refuse?, permitted?(socket, "moderator.sanction_user"))
     |> assign(:refusing, nil)
     |> assign(:page_title, gettext("Admin Pending Users"))}
  end

  @impl true
  def handle_event("approve", %{"id" => id}, socket) do
    with true <- socket.assigns.can_approve?,
         {:ok, user_id} <- parse_id(id),
         %{} = user <- Auth.get_user(user_id),
         {:ok, _user} <- Auth.approve_user(user) do
      Moderation.log_action(socket.assigns.current_user.id, "approve_user",
        target_type: "user",
        target_id: user.id
      )

      {:noreply,
       socket
       |> put_flash(:info, gettext("User approved successfully."))
       |> refresh()}
    else
      false -> {:noreply, put_flash(socket, :error, gettext("You cannot do that."))}
      :error -> {:noreply, socket}
      nil -> {:noreply, put_flash(socket, :error, gettext("User not found."))}
      {:error, _} -> {:noreply, put_flash(socket, :error, gettext("Failed to approve user."))}
    end
  end

  # Opens the reason prompt. A refusal without a reason is a decision nobody
  # can review later, so the reason is asked for before the act, not after.
  def handle_event("refuse_prompt", %{"id" => id}, socket) do
    case parse_id(id) do
      {:ok, user_id} -> {:noreply, assign(socket, :refusing, user_id)}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("refuse_cancel", _params, socket) do
    {:noreply, socket |> assign(:refusing, nil) |> focus_heading()}
  end

  def handle_event("refuse", params, socket) do
    actor = socket.assigns.current_user
    reason = params["reason"] |> to_string() |> String.trim()

    # The target comes from the server's own state, never from the form.
    with true <- socket.assigns.can_refuse?,
         :ok <- RateLimits.check_sanction(actor.id),
         user_id when is_integer(user_id) <- socket.assigns.refusing,
         %{} = user <- Auth.get_user(user_id),
         {:ok, _rejected} <- Auth.reject_pending_user(actor, user, presence(reason)) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Registration refused."))
       |> assign(:refusing, nil)
       |> refresh()}
    else
      false ->
        {:noreply, put_flash(socket, :error, gettext("You cannot do that."))}

      nil ->
        {:noreply, put_flash(socket, :error, gettext("User not found."))}

      {:error, :rate_limited} ->
        {:noreply, put_flash(socket, :error, gettext("Too many actions. Try again shortly."))}

      {:error, :not_pending} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("That account is no longer waiting."))
         |> assign(:refusing, nil)
         |> refresh()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to refuse the registration."))}
    end
  end

  defp refresh(socket) do
    socket
    |> assign(:pending_users, Auth.list_pending_users())
    |> focus_heading()
  end

  # The row that had focus is gone after either action.
  defp focus_heading(socket),
    do: push_event(socket, "focus", %{id: "admin-pending-users-heading"})

  defp permitted?(socket, permission) do
    case socket.assigns[:current_user] do
      %{role: %{name: name}} -> Setup.has_permission?(name, permission)
      _ -> false
    end
  end

  defp presence(""), do: nil
  defp presence(value), do: value
end
