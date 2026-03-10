defmodule Baudrate.Federation.Visibility do
  @moduledoc """
  Derives ActivityPub visibility from `to`/`cc` addressing fields.

  ActivityPub does not have an explicit visibility field. Instead, visibility
  is inferred from the presence and placement of the special public collection
  URI (`https://www.w3.org/ns/activitystreams#Public`) in the `to` and `cc`
  fields:

    * `public` — `as:Public` in `to`
    * `unlisted` — `as:Public` in `cc` (not in `to`)
    * `followers_only` — addressed to a followers collection, no `as:Public`
    * `direct` — addressed to specific actors only
  """

  @as_public "https://www.w3.org/ns/activitystreams#Public"

  @doc """
  Derives visibility from an ActivityPub object or activity map.

  Accepts any map with `"to"` and/or `"cc"` keys. Returns one of:
  `"public"`, `"unlisted"`, `"followers_only"`, or `"direct"`.

  ## Examples

      iex> from_addressing(%{"to" => ["https://www.w3.org/ns/activitystreams#Public"]})
      "public"

      iex> from_addressing(%{"cc" => ["https://www.w3.org/ns/activitystreams#Public"]})
      "unlisted"
  """
  @spec from_addressing(map()) :: String.t()
  def from_addressing(object) when is_map(object) do
    to = List.wrap(object["to"])
    cc = List.wrap(object["cc"])

    cond do
      @as_public in to -> "public"
      @as_public in cc -> "unlisted"
      has_followers_collection?(to ++ cc) -> "followers_only"
      true -> "direct"
    end
  end

  defp has_followers_collection?(uris) do
    Enum.any?(uris, &String.ends_with?(&1, "/followers"))
  end
end
