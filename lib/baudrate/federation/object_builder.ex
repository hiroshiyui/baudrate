defmodule Baudrate.Federation.ObjectBuilder do
  @moduledoc """
  Builds ActivityPub JSON-LD object representations for local content.

  Produces `Article` objects with embedded polls, images, link previews,
  and hashtag tags, suitable for inclusion in outbox activities and for
  serving at AP article endpoints, plus the `Note` and `Question` objects
  served at `/ap/comments/:id` and `/ap/polls/:id` (ADR 0050).

  Each object is built in exactly one place. The `Question` embedded in an
  Article and the one served standalone are the same map with the same `id`,
  so a peer that reads the poll from either sees one object rather than two
  that drift.
  """

  alias Baudrate.Content
  alias Baudrate.Content.Board
  alias Baudrate.Content.ContentWarning
  alias Baudrate.Content.Markdown
  alias Baudrate.Federation.{Context, Delivery, Mentions, Visibility}
  alias Baudrate.Repo

  @as_public "https://www.w3.org/ns/activitystreams#Public"

  @article_preloads [:boards, :user, :link_preview, :article_images, poll: :options]

  @doc """
  Returns an Article JSON-LD map for the given article.

  The one-item case of `article_objects/1`, so a single object and a page of
  them can never be built two different ways.
  """
  def article_object(article), do: article |> List.wrap() |> article_objects() |> hd()

  @doc """
  Article JSON-LD maps for a page of articles, in order, at a fixed number of
  queries (Phase 8D). The associations are preloaded for the whole list, and
  the comment count, like count and whether each article was edited come from
  one grouped query each, where `article_object/1` used to issue all of that
  per item — about 160 queries for a 20-item outbox page. The one lookup that
  stays per article is a remote mention, which queries only when the body
  names a handle.
  """
  @spec article_objects([Content.Article.t()]) :: [map()]
  def article_objects([]), do: []

  def article_objects(articles) when is_list(articles) do
    articles = Repo.preload(articles, @article_preloads)
    ids = Enum.map(articles, & &1.id)

    stats = %{
      comments: Content.count_comments_for_articles(ids),
      likes: Content.count_article_likes_for(ids),
      edited: Content.edited_article_ids(ids)
    }

    Enum.map(articles, &build_article_object(&1, stats))
  end

  defp build_article_object(article, stats) do
    # Only federated boards are named. A board's actor URI carries its slug,
    # so listing a private or AP-disabled board here disclosed that the board
    # exists and what it is called — and this object is served verbatim by
    # three unauthenticated endpoints (`GET /ap/articles/:slug`, the user
    # outbox and `/ap/search`) for any article that is in at least one public
    # board. `Publisher.article_addressing/2` was filtered, but it only
    # overwrites `cc` on the outbound activity, so `audience` still carried
    # the private slug to every recipient.
    board_uris =
      article.boards
      |> Enum.filter(&Board.federated?/1)
      |> Enum.map(&actor_uri(:board, &1.slug))

    # A mention addresses, and the board gate still decides (ADR 0051). An
    # article that may not leave carries no `Mention` tag and no mentioned
    # actor in `cc`, however many handles its body contains — otherwise typing
    # one would be a one-step way to send a private board's article to any
    # instance on the internet, and this object is served verbatim by three
    # unauthenticated endpoints.
    mentioned =
      if Delivery.article_boards_federated?(article),
        do: Mentions.known(article.body),
        else: []

    tags = extract_hashtags(article.body) ++ Mentions.tags(mentioned)

    map = %{
      "@context" => Context.object(),
      "id" => article.ap_id || actor_uri(:article, article.slug),
      "type" => "Article",
      "name" => article.title,
      "content" => Markdown.to_html(article.body),
      "mediaType" => "text/html",
      "source" => %{
        "content" => article.body || "",
        "mediaType" => "text/markdown"
      },
      "attributedTo" => actor_uri(:user, article.user.username),
      "published" => DateTime.to_iso8601(article.inserted_at),
      "to" => [@as_public],
      "cc" => board_uris ++ Mentions.uris(mentioned),
      # `audience` stays the board context only: it says where the article
      # lives, not who was addressed.
      "audience" => board_uris,
      "url" => "#{base_url()}/articles/#{article.slug}",
      "replies" => "#{article.ap_id || actor_uri(:article, article.slug)}/replies",
      "baudrate:pinned" => article.pinned,
      "baudrate:locked" => article.locked,
      "baudrate:commentCount" => Map.fetch!(stats.comments, article.id),
      "baudrate:likeCount" => Map.fetch!(stats.likes, article.id)
    }

    map = put_updated(map, article, article.id in stats.edited)

    map = if tags == [], do: map, else: Map.put(map, "tag", tags)

    map
    |> put_content_warning(article)
    |> maybe_embed_images(article.article_images)
    |> maybe_embed_poll(article.poll)
    |> maybe_embed_link_preview(article)
  end

  @doc """
  Returns a `Note` JSON-LD map for a local comment, served at
  `/ap/comments/:id`.

  Callers are responsible for the gate: this builds the object, it does not
  decide who may see it. `BaudrateWeb.ActivityPubController` applies the
  article's `publicly_servable?/1` before calling.
  """
  def comment_object(comment) do
    comment = Repo.preload(comment, [:user, :images, article: [:boards, :user]])
    article = comment.article
    actor_uri = actor_uri(:user, comment.user.username)
    {to, cc} = Visibility.to_addressing(comment.visibility, "#{actor_uri}/followers")

    # The comment inherits its article's reach, for mentions as for everything
    # else (ADR 0051).
    mentioned =
      if Delivery.article_boards_federated?(article),
        do: Mentions.known(comment.body),
        else: []

    map = %{
      "@context" => Context.object(),
      "id" => comment.ap_id || actor_uri(:comment, comment.id),
      "type" => "Note",
      "url" => comment_url(comment),
      "content" => comment.body_html || comment.body || "",
      "mediaType" => "text/html",
      "attributedTo" => actor_uri,
      "inReplyTo" => reply_target_uri(comment, article),
      "published" => DateTime.to_iso8601(comment.inserted_at),
      "to" => to,
      "cc" => cc ++ Mentions.uris(mentioned)
    }

    map = if mentioned == [], do: map, else: Map.put(map, "tag", Mentions.tags(mentioned))

    map = put_updated(map, comment, Content.comment_edited?(comment))

    map
    |> put_content_warning(comment)
    |> maybe_embed_comment_images(comment.images)
  end

  @doc """
  Returns a standalone `Question` JSON-LD map for a local poll, served at
  `/ap/polls/:id`.

  The same body the owning Article embeds, plus the `@context`, addressing and
  navigation an object needs when it is fetched on its own. `context` rather
  than `inReplyTo`: the poll belongs to its article, it is not a reply to it,
  and Mastodon would render an `inReplyTo` as one.
  """
  def poll_object(poll) do
    poll = Repo.preload(poll, [:options, article: [:boards, :user]])
    article = poll.article
    article_uri = article.ap_id || actor_uri(:article, article.slug)

    board_uris =
      article.boards
      |> Enum.filter(&Board.federated?/1)
      |> Enum.map(&actor_uri(:board, &1.slug))

    poll
    |> question_body()
    |> Map.merge(%{
      "@context" => Context.object(),
      "id" => poll.ap_id || actor_uri(:poll, poll.id),
      "name" => article.title,
      "attributedTo" => actor_uri(:user, article.user.username),
      "context" => article_uri,
      "url" => "#{base_url()}/articles/#{article.slug}",
      "published" => DateTime.to_iso8601(article.inserted_at),
      "to" => [@as_public],
      "cc" => board_uris
    })
  end

  # A local comment's human address is its permalink, which redirects to the
  # page the comment is on. The stored `url` of a comment written before that
  # route existed is `/articles/:slug#comment-N`, which finds it only while it
  # is on page 1, so it is not used — only local comments are published here.
  defp comment_url(comment), do: "#{base_url()}/comments/#{comment.id}"

  @doc """
  The URI a comment replies to: its parent comment when it has one, otherwise
  the article.

  Threading on the receiving side is `inReplyTo`, and nothing else. Until
  Phase 3A every comment named the article, so a remote instance had no way to
  know a reply was a reply and rendered the whole discussion flat — and until
  [ADR 0050](../../../doc/adr/0050-a-comment-and-a-poll-are-objects-with-their-own-uri.md)
  gave a comment a dereferenceable id there was nothing it *could* have named.

  A remote parent's own `ap_id` is used as it stands, which is what threads
  the reply back into the conversation on the instance it started from. A
  parent that has somehow lost its `ap_id`, or has been hard-deleted, falls
  back to the article: a reply that lands in the right thread at the wrong
  depth is better than one that names a URI nobody can resolve.
  """
  @spec reply_target_uri(map(), map()) :: String.t()
  def reply_target_uri(%{parent_id: parent_id}, article) when is_integer(parent_id) do
    case Repo.get(Content.Comment, parent_id) do
      %{ap_id: ap_id} when is_binary(ap_id) and ap_id != "" -> ap_id
      _ -> article_uri(article)
    end
  end

  def reply_target_uri(_comment, article), do: article_uri(article)

  defp article_uri(article), do: article.ap_id || actor_uri(:article, article.slug)

  # --- Private ---

  # `summary` is the **content warning**, and nothing else (ADR 0052).
  #
  # It used to carry a 500-character excerpt of the body, which is a defensible
  # reading of AS2 for an `Article` and a bad one in practice: Mastodon maps
  # `summary` to `spoiler_text` for every object type, so every Baudrate
  # article arrived on Mastodon hidden behind a "content warning" that was
  # actually its own opening paragraph. The excerpt is gone rather than moved
  # — `name` already carries the title and `content` the body, so it was
  # telling a reader nothing they could not see.
  defp put_content_warning(map, record) do
    if ContentWarning.warned?(record) do
      map
      |> Map.put("sensitive", true)
      |> put_if_present("summary", record.summary)
    else
      map
    end
  end

  defp put_if_present(map, _key, value) when value in [nil, ""], do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  # An image's description travels as the attachment `name` — what every
  # fediverse client renders as alt text, and what `AttachmentExtractor` reads
  # back off an inbound attachment. Absent when nobody wrote one: an empty
  # `name` would claim the image is decorative, which is a different statement
  # from "undescribed" and a false one for a photograph somebody posted.
  # Mastodon shows "edited" whenever `updated` differs from `published`, so
  # this field has to mean an edit and nothing else.
  #
  # It used to be derived from `updated_at` being more than five seconds past
  # `inserted_at`. That was a proxy for the fact, and the proxy broke: the
  # v1.31.0 `ap_id` backfill rewrote rows with an ordinary changeset months
  # after they were written, so every comment it touched began federating as
  # edited on the day of the backfill — while the site's own history page,
  # which counts revisions, correctly said it had never been edited. Two
  # surfaces disagreeing about the same comment is the bug; picking whichever
  # is easier to compute is how it happened.
  #
  # So the *fact* comes from the revision table and only the *timestamp* comes
  # from `updated_at`, which is the right value once an edit is known to have
  # happened. Any future housekeeping write is then harmless here.
  defp put_updated(map, _record, false), do: map

  defp put_updated(map, record, true),
    do: Map.put(map, "updated", DateTime.to_iso8601(record.updated_at))

  defp put_attachment_name(attachment, image),
    do: put_if_present(attachment, "name", Content.ImageAlt.describe(image))

  defp maybe_embed_comment_images(map, images) when is_list(images) and images != [] do
    attachments =
      Enum.map(images, fn img ->
        %{
          "type" => "Image",
          "mediaType" => "image/webp",
          "url" => "#{base_url()}#{Content.ArticleImageStorage.image_url(img.filename)}",
          "width" => img.width,
          "height" => img.height
        }
        |> put_attachment_name(img)
      end)

    # Appended, not assigned: nothing else puts an `attachment` on a comment
    # today, so `Map.put/3` was harmless — but it was the one builder here
    # that would silently drop a sibling's work if one ever did.
    Map.put(map, "attachment", Map.get(map, "attachment", []) ++ attachments)
  end

  defp maybe_embed_comment_images(map, _images), do: map

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
        |> put_attachment_name(img)
      end)

    existing = Map.get(map, "attachment", [])
    Map.put(map, "attachment", existing ++ attachments)
  end

  defp maybe_embed_poll(map, nil), do: map

  defp maybe_embed_poll(map, %Content.Poll{} = poll) do
    existing_attachment = Map.get(map, "attachment", [])
    Map.put(map, "attachment", existing_attachment ++ [question_body(poll)])
  end

  # The `Question` itself, without the `@context` and addressing that only a
  # standalone object needs. Carries the poll's `id`, so a peer reading the
  # embedded copy can fetch, vote against and later re-read the same object
  # rather than having to address the whole Article.
  #
  # Each option's `replies` Collection gives `totalItems` and deliberately no
  # `items`: the count is public, the voters are not (ADR 0048).
  defp question_body(%Content.Poll{} = poll) do
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

    question = if poll.ap_id, do: Map.put(question, "id", poll.ap_id), else: question

    if poll.closes_at do
      Map.put(question, "endTime", DateTime.to_iso8601(poll.closes_at))
    else
      question
    end
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
