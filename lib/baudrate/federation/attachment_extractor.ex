defmodule Baudrate.Federation.AttachmentExtractor do
  @moduledoc """
  Extracts attachments from ActivityPub object `attachment` arrays.

  Mastodon sends `Document` with `mediaType` starting with "image/";
  some implementations use `Image` type. Returns a list of maps with
  `url`, `media_type`, and optional `name` (alt text).

  ## Images and everything else

  Images and playable media are extracted separately and on purpose. An image
  is rendered through `Baudrate.Media.Proxy`, so the page never asks the
  viewer's browser to fetch from another host (ADR 0006). **Video and audio
  cannot be**: proxying them would mean this instance downloading and
  re-serving arbitrarily large files, and embedding them directly would be the
  hotlink the proxy exists to prevent — the same reasoning that makes a
  YouTube embed click-to-load (ADR 0045).

  So they are rendered as a **link to the original**, which contacts nobody
  until the reader chooses to follow it. Before this they were dropped
  silently, which was safe and told the reader nothing: a post whose whole
  point was a video looked empty.
  """

  @max_attachments 4

  @playable_prefixes ["video/", "audio/"]

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

  @doc """
  Extracts video and audio attachment metadata from an AP object.

  Same shape as `extract_image_attachments/1`, so both can live in one
  `attachments` column and be told apart by `media_type`. A renderer must
  branch on it: these are links, never `<img>` and never an embedded player.
  """
  @spec extract_media_attachments(map()) :: [map()]
  def extract_media_attachments(%{"attachment" => attachments}) when is_list(attachments) do
    attachments
    |> Enum.filter(fn
      %{"mediaType" => mt} when is_binary(mt) -> playable?(mt)
      _ -> false
    end)
    |> Enum.map(&normalize/1)
    |> Enum.filter(&is_binary(&1["url"]))
    |> Enum.take(@max_attachments)
  end

  def extract_media_attachments(_), do: []

  @doc "Whether a stored attachment is playable media rather than an image."
  @spec playable?(String.t() | nil) :: boolean()
  def playable?(media_type) when is_binary(media_type),
    do: Enum.any?(@playable_prefixes, &String.starts_with?(media_type, &1))

  def playable?(_), do: false

  defp normalize(att) do
    url =
      case att["url"] do
        url when is_binary(url) -> url
        [first | _] -> if(is_binary(first), do: first, else: first["href"])
        %{"href" => href} -> href
        _ -> nil
      end

    %{"url" => url, "media_type" => att["mediaType"], "name" => att["name"]}
  end
end
