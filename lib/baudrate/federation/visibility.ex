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

  `to_addressing/2` is the same mapping in the other direction. Both live here
  so the round trip cannot drift: a value this module writes must be a value it
  reads back the same way.
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
    to = addressees(object["to"])
    cc = addressees(object["cc"])

    cond do
      Enum.any?(to, &public_collection?/1) -> "public"
      Enum.any?(cc, &public_collection?/1) -> "unlisted"
      has_followers_collection?(to ++ cc) -> "followers_only"
      true -> "direct"
    end
  end

  @doc """
  Builds `{to, cc}` for a local object of the given visibility.

  The inverse of `from_addressing/1`: feeding the result back in returns the
  visibility it was built from.

  ## Examples

      iex> to_addressing("public", "https://example.com/ap/users/alice/followers")
      {["https://www.w3.org/ns/activitystreams#Public"],
       ["https://example.com/ap/users/alice/followers"]}

      iex> to_addressing("direct", "https://example.com/ap/users/alice/followers")
      {[], []}
  """
  @spec to_addressing(String.t(), String.t()) :: {[String.t()], [String.t()]}
  def to_addressing(visibility, followers_uri) do
    case visibility do
      "unlisted" -> {[followers_uri], [@as_public]}
      "followers_only" -> {[followers_uri], []}
      "direct" -> {[], []}
      # "public" or default
      _ -> {[@as_public], [followers_uri]}
    end
  end

  # The public collection may appear as the full IRI or in either JSON-LD
  # compact form (`as:Public`, `Public`) — ActivityPub §5.6 treats all three
  # as equivalent. Missing the compact forms would mis-derive genuinely public
  # content from peers that compact it as "direct" and hide it.
  defp public_collection?(uri), do: uri in [@as_public, "as:Public", "Public"]

  # Addressing values are remote-controlled: accept strings and `{"id": ...}`
  # link objects, drop everything else (a non-string entry used to crash
  # `String.ends_with?/2`).
  defp addressees(value) do
    value
    |> List.wrap()
    |> Enum.flat_map(fn
      uri when is_binary(uri) -> [uri]
      %{"id" => uri} when is_binary(uri) -> [uri]
      _ -> []
    end)
  end

  defp has_followers_collection?(uris) do
    Enum.any?(uris, &String.ends_with?(&1, "/followers"))
  end
end
