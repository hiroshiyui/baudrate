defmodule Baudrate.Repo.Migrations.BackfillArticleTags do
  use Ecto.Migration

  import Ecto.Query

  @hashtag_re ~r/(?:^|(?<=\s|[^\w&]))#(\p{L}[\w]{0,63})/u
  @batch_size 500

  def up do
    # Process articles in batches to avoid long locks
    repo().transaction(
      fn ->
        from(a in "articles",
          where: is_nil(a.deleted_at) and not is_nil(a.body),
          select: %{id: a.id, body: a.body},
          order_by: a.id
        )
        |> repo().stream(max_rows: @batch_size)
        |> Stream.flat_map(fn %{id: article_id, body: body} ->
          extract_tags(body)
          |> Enum.map(fn tag ->
            %{
              article_id: article_id,
              tag: tag,
              inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
            }
          end)
        end)
        |> Stream.chunk_every(@batch_size)
        |> Stream.each(fn batch ->
          repo().insert_all("article_tags", batch, on_conflict: :nothing)
        end)
        |> Stream.run()
      end,
      timeout: :infinity
    )
  end

  def down do
    repo().delete_all("article_tags")
  end

  defp extract_tags(nil), do: []
  defp extract_tags(""), do: []

  defp extract_tags(body) do
    cleaned =
      body
      |> String.replace(~r/```[\s\S]*?```/u, "")
      |> String.replace(~r/`[^`]+`/, "")

    Regex.scan(@hashtag_re, cleaned, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end
end
