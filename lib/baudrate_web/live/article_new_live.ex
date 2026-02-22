defmodule BaudrateWeb.ArticleNewLive do
  @moduledoc """
  LiveView for creating new articles.

  Accessible from both board pages (pre-selects that board via `board_slug`
  param) and as a standalone route at `/articles/new` where the user picks
  boards from a multi-select.

  Requires the user to be active and have `user.create_content` permission.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Auth
  alias Baudrate.Content

  @impl true
  def mount(params, _session, socket) do
    user = socket.assigns.current_user

    unless Auth.can_create_content?(user) do
      {:ok,
       socket
       |> put_flash(:error, gettext("Your account is pending approval."))
       |> redirect(to: ~p"/")}
    else
      boards = Content.list_top_boards() |> Enum.filter(&Content.can_post_in_board?(&1, user))

      selected_board_ids =
        case params do
          %{"slug" => slug} ->
            board = Content.get_board_by_slug!(slug)
            [board.id]

          _ ->
            []
        end

      changeset = Content.change_article()

      {:ok,
       socket
       |> assign(:form, to_form(changeset, as: :article))
       |> assign(:boards, boards)
       |> assign(:selected_board_ids, selected_board_ids)
       |> assign(:board_slug, params["slug"])}
    end
  end

  @impl true
  def handle_event("validate", %{"article" => params}, socket) do
    changeset =
      Content.change_article(%Baudrate.Content.Article{}, params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset, as: :article))}
  end

  @impl true
  def handle_event("submit", %{"article" => params, "board_ids" => board_ids}, socket) do
    do_create(socket, params, board_ids)
  end

  def handle_event("submit", %{"article" => params}, socket) do
    do_create(socket, params, [])
  end

  defp do_create(socket, params, board_ids) do
    board_ids = Enum.map(List.wrap(board_ids), &String.to_integer/1)

    if board_ids == [] do
      {:noreply, put_flash(socket, :error, gettext("Please select at least one board."))}
    else
      user = socket.assigns.current_user
      slug = Content.generate_slug(params["title"] || "")

      attrs =
        params
        |> Map.put("slug", slug)
        |> Map.put("user_id", user.id)

      case Content.create_article(attrs, board_ids) do
        {:ok, %{article: article}} ->
          # Redirect to the article
          {:noreply,
           socket
           |> put_flash(:info, gettext("Article created successfully."))
           |> redirect(to: ~p"/articles/#{article.slug}")}

        {:error, :article, changeset, _} ->
          {:noreply, assign(socket, :form, to_form(changeset, as: :article))}

        {:error, _, _, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to create article."))}
      end
    end
  end
end
