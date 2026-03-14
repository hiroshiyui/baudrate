defmodule Baudrate.Federation.ObjectBuilder do
  @moduledoc """
  Builds ActivityPub JSON-LD object representations for local content.

  Produces `Article` objects with embedded polls, images, link previews,
  and hashtag tags, suitable for inclusion in outbox activities and for
  serving at AP article endpoints.
  """

  alias Baudrate.Content
  alias Baudrate.Content.Markdown
  alias Baudrate.Repo

  @as_context "https://www.w3.org/ns/activitystreams"
  @as_public "https://www.w3.org/ns/activitystreams#Public"

  @doc """
  Returns an Article JSON-LD map for the given article.
  """
  def article_object(article) do
    article =
      Repo.preload(article, [:boards, :user, :link_preview, :article_images, poll: :options])

    board_uris =
      Enum.map(article.boards, fn board ->
        actor_uri(:board, board.slug)
      end)

    tags = extract_hashtags(article.body)

    map = %{
      "@context" => @as_context,
      "id" => article.ap_id || actor_uri(:article, article.slug),
      "type" => "Article",
      "name" => article.title,
      "summary" => build_article_summary(article.body),
      "content" => Markdown.to_html(article.body),
      "mediaType" => "text/html",
      "source" => %{
        "content" => article.body || "",
        "mediaType" => "text/markdown"
      },
      "attributedTo" => actor_uri(:user, article.user.username),
      "published" => DateTime.to_iso8601(article.inserted_at),
      "to" => [@as_public],
      "cc" => board_uris,
      "audience" => board_uris,
      "url" => "#{base_url()}/articles/#{article.slug}",
      "replies" => "#{article.ap_id || actor_uri(:article, article.slug)}/replies",
      "baudrate:pinned" => article.pinned,
      "baudrate:locked" => article.locked,
      "baudrate:commentCount" => Content.count_comments_for_article(article),
      "baudrate:likeCount" => Content.count_article_likes(article)
    }

    # Only include "updated" if the article was genuinely edited (not just
    # post-insert housekeeping like ap_id stamping or body_html rendering).
    # Mastodon shows "edited" whenever updated != published.
    map =
      if DateTime.diff(article.updated_at, article.inserted_at) > 5 do
        Map.put(map, "updated", DateTime.to_iso8601(article.updated_at))
      else
        map
      end

    map = if tags == [], do: map, else: Map.put(map, "tag", tags)

    map
    |> maybe_embed_images(article.article_images)
    |> maybe_embed_poll(article.poll)
    |> maybe_embed_link_preview(article)
  end

  # --- Private ---

  defp maybe_embed_images(map, []), do: map
  defp maybe_embed_images(map, nil), do: map

  defp maybe_embed_images(map, images) do
    attachments =
      Enum.map(images, fn img ->
        %{
          "type" => "Document",
          "mediaType" => "image/webp",
          "url" => "#{base_url()}#{Content.ArticleImageStorage.image_url(img.filename)}",
          "width" => img.width,
          "height" => img.height
        }
      end)

    existing = Map.get(map, "attachment", [])
    Map.put(map, "attachment", existing ++ attachments)
  end

  defp maybe_embed_poll(map, nil), do: map

  defp maybe_embed_poll(map, %Content.Poll{} = poll) do
    choice_key = if poll.mode == "single", do: "oneOf", else: "anyOf"

    options =
      Enum.map(poll.options, fn opt ->
        %{
          "type" => "Note",
          "name" => opt.text,
          "replies" => %{
            "type" => "Collection",
            "totalItems" => opt.votes_count
          }
        }
      end)

    question = %{
      "type" => "Question",
      choice_key => options,
      "votersCount" => poll.voters_count
    }

    question =
      if poll.closes_at do
        Map.put(question, "endTime", DateTime.to_iso8601(poll.closes_at))
      else
        question
      end

    existing_attachment = Map.get(map, "attachment", [])
    Map.put(map, "attachment", existing_attachment ++ [question])
  end

  defp maybe_embed_link_preview(
         map,
         %{link_preview: %Content.LinkPreview{status: "fetched"} = lp}
       ) do
    attachment = %{
      "type" => "Document",
      "mediaType" => "text/html",
      "url" => lp.url,
      "name" => lp.title || lp.url
    }

    existing = Map.get(map, "attachment", [])
    Map.put(map, "attachment", existing ++ [attachment])
  end

  defp maybe_embed_link_preview(map, _), do: map

  defp build_article_summary(nil), do: ""

  defp build_article_summary(body) do
    body
    |> strip_markdown()
    |> truncate_text(500)
  end

  defp strip_markdown(text) do
    text
    |> String.replace(~r/```[\s\S]*?```/u, "")
    |> String.replace(~r/`[^`]+`/, "")
    |> String.replace(~r/!\[[^\]]*\]\([^)]*\)/, "")
    |> String.replace(~r/\[[^\]]*\]\([^)]*\)/, fn m ->
      case Regex.run(~r/\[([^\]]*)\]/, m) do
        [_, text] -> text
        _ -> m
      end
    end)
    |> String.replace(~r/^\#{1,6}\s+/m, "")
    |> String.replace(~r/[*_~]{1,3}/, "")
    |> String.replace(~r/^>\s?/m, "")
    |> String.replace(~r/^[-*+]\s/m, "")
    |> String.replace(~r/^\d+\.\s/m, "")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  defp truncate_text(text, max_length) do
    if String.length(text) <= max_length do
      text
    else
      text
      |> String.slice(0, max_length)
      |> String.replace(~r/\s\S*$/, "")
      |> Kernel.<>("…")
    end
  end

  defp extract_hashtags(nil), do: []

  defp extract_hashtags(body) do
    Baudrate.Content.extract_tags(body)
    |> Enum.map(fn tag ->
      %{
        "type" => "Hashtag",
        "name" => "##{tag}",
        "href" => "#{base_url()}/tags/#{tag}"
      }
    end)
  end

  defp actor_uri(type, id), do: Baudrate.Federation.actor_uri(type, id)
  defp base_url, do: Baudrate.Federation.base_url()
end
