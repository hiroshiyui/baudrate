defmodule Baudrate.Content.LinkPreview.Worker do
  @moduledoc """
  Schedules async link preview fetches after content creation.

  Uses `Task.Supervisor` (async in prod, sync in test via `federation_async`
  config) to avoid blocking content saves. After fetching, updates the
  content record's `link_preview_id` and broadcasts a PubSub event.
  """

  require Logger

  import Ecto.Query

  alias Baudrate.Content.LinkPreview
  alias Baudrate.Content.LinkPreview.{Fetcher, UrlExtractor}
  alias Baudrate.Content.PubSub, as: ContentPubSub
  alias Baudrate.Repo

  @doc """
  Schedules a link preview fetch for the given content.

  `content_type` is one of `:article`, `:comment`, `:direct_message`,
  `:feed_item`, `:feed_item_reply`.
  """
  @spec schedule_preview_fetch(atom(), integer(), String.t(), integer() | nil) :: :ok
  def schedule_preview_fetch(content_type, content_id, html, user_id \\ nil)
      when is_atom(content_type) and is_integer(content_id) do
    fun = fn ->
      do_fetch(content_type, content_id, html, user_id)
    end

    if Application.get_env(:baudrate, :federation_async, true) do
      Task.Supervisor.start_child(Baudrate.Federation.TaskSupervisor, fun)
    else
      fun.()
    end

    :ok
  end

  defp do_fetch(content_type, content_id, html, user_id) do
    case UrlExtractor.extract_first_url(html) do
      {:ok, url} ->
        case Fetcher.fetch_or_get(url, user_id) do
          {:ok, %LinkPreview{id: preview_id}} ->
            update_content_preview(content_type, content_id, preview_id)
            broadcast_preview_fetched(content_type, content_id)

          {:error, reason} ->
            Logger.debug(
              "link_preview.fetch_failed: type=#{content_type} id=#{content_id} reason=#{inspect(reason)}"
            )
        end

      :none ->
        :ok
    end
  rescue
    e ->
      Logger.warning(
        "link_preview.worker_error: type=#{content_type} id=#{content_id} error=#{Exception.message(e)}"
      )
  end

  defp update_content_preview(content_type, content_id, preview_id) do
    {table, schema} = content_schema(content_type)

    from(r in schema, where: r.id == ^content_id)
    |> Repo.update_all(set: [link_preview_id: preview_id])

    Logger.debug(
      "link_preview.attached: table=#{table} id=#{content_id} preview_id=#{preview_id}"
    )
  end

  defp broadcast_preview_fetched(:article, article_id) do
    ContentPubSub.broadcast_to_article(article_id, :link_preview_fetched, %{
      article_id: article_id
    })
  end

  defp broadcast_preview_fetched(:comment, comment_id) do
    # Look up the article_id for this comment
    case Repo.one(
           from(c in Baudrate.Content.Comment, where: c.id == ^comment_id, select: c.article_id)
         ) do
      nil ->
        :ok

      article_id ->
        ContentPubSub.broadcast_to_article(article_id, :link_preview_fetched, %{
          comment_id: comment_id
        })
    end
  end

  defp broadcast_preview_fetched(:direct_message, message_id) do
    case Repo.one(
           from(m in Baudrate.Messaging.DirectMessage,
             where: m.id == ^message_id,
             select: m.conversation_id
           )
         ) do
      nil ->
        :ok

      conversation_id ->
        Baudrate.Messaging.PubSub.broadcast_to_conversation(
          conversation_id,
          :link_preview_fetched,
          %{message_id: message_id}
        )
    end
  end

  defp broadcast_preview_fetched(_type, _id), do: :ok

  defp content_schema(:article), do: {"articles", Baudrate.Content.Article}
  defp content_schema(:comment), do: {"comments", Baudrate.Content.Comment}
  defp content_schema(:direct_message), do: {"direct_messages", Baudrate.Messaging.DirectMessage}
  defp content_schema(:feed_item), do: {"feed_items", Baudrate.Federation.FeedItem}

  defp content_schema(:feed_item_reply),
    do: {"feed_item_replies", Baudrate.Federation.FeedItemReply}
end
