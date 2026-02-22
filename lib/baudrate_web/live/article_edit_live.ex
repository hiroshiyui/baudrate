defmodule BaudrateWeb.ArticleEditLive do
  @moduledoc """
  LiveView for editing an existing article.

  Only the article author or an admin can access this page.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Content

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    article = Content.get_article_by_slug!(slug)
    user = socket.assigns.current_user

    if Content.can_edit_article?(user, article) do
      changeset = Content.change_article_for_edit(article)

      {:ok,
       socket
       |> assign(:article, article)
       |> assign(:form, to_form(changeset, as: :article))}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You are not authorized to edit this article."))
       |> redirect(to: ~p"/articles/#{article.slug}")}
    end
  end

  @impl true
  def handle_event("validate", %{"article" => params}, socket) do
    changeset =
      Content.change_article_for_edit(socket.assigns.article, params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset, as: :article))}
  end

  @impl true
  def handle_event("submit", %{"article" => params}, socket) do
    case Content.update_article(socket.assigns.article, params) do
      {:ok, updated_article} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Article updated successfully."))
         |> redirect(to: ~p"/articles/#{updated_article.slug}")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :article))}
    end
  end
end
