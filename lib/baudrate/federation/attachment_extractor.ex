defmodule Baudrate.Federation.AttachmentExtractor do
  @moduledoc """
  Extracts image attachments from ActivityPub object `attachment` arrays.

  Mastodon sends `Document` with `mediaType` starting with "image/";
  some implementations use `Image` type. Returns a list of maps with
  `url`, `media_type`, and optional `name` (alt text).
  """

  @max_attachments 4

  @doc """
  Extracts image attachment metadata from an AP object.

  Returns a list of maps with `"url"`, `"media_type"`, and `"name"` keys.
  Takes up to #{@max_attachments} image attachments.
  """
  @spec extract_image_attachments(map()) :: [map()]
  def extract_image_attachments(%{"attachment" => attachments}) when is_list(attachments) do
    attachments
    |> Enum.filter(fn
      %{"type" => type, "mediaType" => mt} when type in ["Document", "Image"] ->
        String.starts_with?(mt, "image/")

      %{"type" => "Image", "url" => url} when is_binary(url) ->
        true

      _ ->
        false
    end)
    |> Enum.map(fn att ->
      url = att["url"]

      url =
        cond do
          is_binary(url) -> url
          is_list(url) -> List.first(url)
          is_map(url) -> url["href"]
          true -> nil
        end

      %{"url" => url, "media_type" => att["mediaType"], "name" => att["name"]}
    end)
    |> Enum.filter(&is_binary(&1["url"]))
    |> Enum.take(@max_attachments)
  end

  def extract_image_attachments(_), do: []
end
