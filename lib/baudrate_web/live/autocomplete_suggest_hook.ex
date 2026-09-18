defmodule BaudrateWeb.AutocompleteSuggestHook do
  @moduledoc """
  LiveView `attach_hook` that answers the `"hashtag_suggest"` and
  `"mention_suggest"` events sent by the JS `HashtagAutocompleteHook`.

  That JS hook is attached to every Markdown textarea rendered with the
  toolbar (`<.input type="textarea" toolbar>`), on any page. Handling the
  events here, for every authenticated LiveView, means a page that renders
  such a textarea can never lack the handlers. Before this, each LiveView had
  its own copy; `/profile` and `/admin/settings` had none, so typing `#` or
  `@` there crashed the LiveView process.

  Suggestions:

    * `hashtag_suggest` — existing tags (`Content.search_tags/2`).
    * `mention_suggest` — local users other than the current user
      (`Auth.search_users/2`), plus, on a page with an `:article` assign (the
      article and its edit form), the remote actors taking part in that
      article's discussion (`Content.search_discussion_remote_actors/3`).

  Attach it in `on_mount` callbacks via `attach(socket)`, next to
  `BaudrateWeb.MarkdownPreviewHook`.
  """

  import Phoenix.LiveView

  alias Baudrate.{Auth, Content}
  alias BaudrateWeb.RateLimits

  @limit 10

  @doc """
  Attaches the `:autocomplete_suggest` handle_event hook to the socket.

  Returns the socket unchanged if the lifecycle system is not initialized
  (e.g. in unit tests with bare `%Socket{}`).
  """
  def attach(%{private: %{lifecycle: _}} = socket) do
    attach_hook(socket, :autocomplete_suggest, :handle_event, &handle_event/3)
  end

  def attach(socket), do: socket

  @doc false
  # Two bounds, because these are attached to every authenticated LiveView and
  # a suggest is an ILIKE over `users` or `tags`: a per-user rate limit, and a
  # minimum prefix length, since `%a%` is a sequential scan and one socket
  # walking `a`, `b`, …, `aa` enumerated the whole member roster.
  @min_prefix 2

  def handle_event("hashtag_suggest", %{"prefix" => prefix}, socket) when is_binary(prefix) do
    if suggest_allowed?(socket, prefix) do
      tags = Content.search_tags(prefix, limit: @limit)
      {:halt, push_event(socket, "hashtag_suggestions", %{tags: tags})}
    else
      {:halt, push_event(socket, "hashtag_suggestions", %{tags: []})}
    end
  end

  def handle_event("mention_suggest", %{"prefix" => prefix}, socket) when is_binary(prefix) do
    current_user = socket.assigns[:current_user]

    if suggest_allowed?(socket, prefix) do
      local_users =
        prefix
        |> Auth.search_users(limit: @limit, exclude_id: current_user && current_user.id)
        |> Enum.map(&%{username: &1.username, type: "local"})

      {:halt,
       push_event(socket, "mention_suggestions", %{
         users: local_users ++ remote_actors(socket, prefix)
       })}
    else
      {:halt, push_event(socket, "mention_suggestions", %{users: []})}
    end
  end

  # A malformed suggest event is dropped rather than crashing the LiveView.
  def handle_event(event, _params, socket) when event in ["hashtag_suggest", "mention_suggest"],
    do: {:halt, socket}

  def handle_event(_event, _params, socket), do: {:cont, socket}

  defp suggest_allowed?(socket, prefix) do
    trimmed = String.trim(prefix)

    cond do
      String.length(trimmed) < @min_prefix -> false
      String.length(trimmed) > 64 -> false
      is_nil(socket.assigns[:current_user]) -> false
      true -> RateLimits.check_suggest(socket.assigns.current_user.id) == :ok
    end
  end

  defp remote_actors(socket, prefix) do
    case socket.assigns[:article] do
      %Content.Article{id: article_id} ->
        article_id
        |> Content.search_discussion_remote_actors(prefix, limit: @limit)
        |> Enum.map(&%{username: &1.username, domain: &1.domain, type: "remote"})

      _ ->
        []
    end
  end
end
