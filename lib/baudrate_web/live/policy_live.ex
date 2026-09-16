defmodule BaudrateWeb.PolicyLive do
  @moduledoc """
  The three public policy documents: the terms (`/terms`), the site rules
  (`/rules`) and the privacy policy (`/privacy`).

  Each is admin-authored markdown held in a setting and rendered through
  `Baudrate.Content.Markdown.to_html/1`, which sanitizes it and rewrites remote
  images to the media proxy — a policy page discloses no more about its reader
  to a third party than an article does.

  All three are readable by guests, and deliberately live outside
  `live_session :public`: that session carries `:redirect_if_authenticated`,
  which would bounce a signed-in member off the very document they are being
  asked to accept. A document nobody can re-read after registering is not
  published, only displayed once.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Auth
  alias Baudrate.Setup

  @impl true
  def mount(_params, _session, socket) do
    name = socket.assigns.live_action

    {:ok,
     socket
     |> assign(:policy, name)
     |> assign(:page_title, title(name))
     |> assign(:body, Setup.get_policy(name))}
  end

  @impl true
  def handle_event("accept_terms", _params, socket) do
    # The version accepted is read at this moment inside the context, never
    # carried in the form: this page may have been open since before the terms
    # changed.
    case socket.assigns[:current_user] do
      nil ->
        {:noreply, socket}

      user ->
        case Auth.accept_current_terms(user) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> assign(current_user: updated, terms_pending: false)
             |> put_flash(:info, gettext("Thank you. You can post again."))
             |> push_event("focus", %{id: "policy-heading"})}

          {:error, _changeset} ->
            {:noreply,
             put_flash(socket, :error, gettext("That could not be saved. Please try again."))}
        end
    end
  end

  @doc """
  The heading and browser title for one policy document.
  """
  def title(:terms), do: gettext("Terms of Service")
  def title(:rules), do: gettext("Site Rules")
  def title(:privacy), do: gettext("Privacy Policy")

  @doc """
  What the page says before an admin has written the document.

  An empty page leaves a reader unable to tell "this site has no rules" from
  "this site is broken", so each document says which one it is.
  """
  def empty_message(:terms), do: gettext("The terms of service have not been published yet.")
  def empty_message(:rules), do: gettext("The site rules have not been published yet.")
  def empty_message(:privacy), do: gettext("The privacy policy has not been published yet.")
end
