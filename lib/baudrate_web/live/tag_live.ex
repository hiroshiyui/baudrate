defmodule BaudrateWeb.TagLive do
  @moduledoc """
  LiveView for browsing articles by hashtag.

  Displays a paginated list of articles tagged with a given hashtag.
  Respects board visibility and block/mute filters.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Content

  @tag_re ~r/\A\p{L}[\w]{0,63}\z/u

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"tag" => raw_tag} = params, _uri, socket) do
    tag = String.downcase(raw_tag)

    if Regex.match?(@tag_re, tag) do
      page =
        case Integer.parse(params["page"] || "1") do
          {n, ""} when n > 0 -> n
          _ -> 1
        end

      user = socket.assigns[:current_user]

      result = Content.articles_by_tag(tag, page: page, user: user)

      {:noreply,
       socket
       |> assign(:tag, tag)
       |> assign(:articles, result.articles)
       |> assign(:total, result.total)
       |> assign(:page, result.page)
       |> assign(:total_pages, result.total_pages)
       |> assign(:page_title, gettext("Articles tagged #%{tag}", tag: tag))}
    else
      {:noreply,
       socket
       |> assign(:tag, raw_tag)
       |> assign(:articles, [])
       |> assign(:total, 0)
       |> assign(:page, 1)
       |> assign(:total_pages, 1)
       |> assign(:page_title, gettext("Articles tagged #%{tag}", tag: raw_tag))}
    end
  end
end
