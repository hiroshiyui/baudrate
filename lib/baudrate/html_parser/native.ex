defmodule Baudrate.HtmlParser.Native do
  @moduledoc """
  Rustler NIF bindings to the `baudrate_html_parser` Rust crate.

  Provides HTML parsing functions backed by
  [html5ever](https://github.com/servo/html5ever) via the `scraper` crate:

    * `parse_og_metadata/1` — extract Open Graph / Twitter Card / fallback metadata
    * `extract_urls/2` — every distinct external URL in an HTML fragment
    * `extract_first_url/2` — the first of those
    * `count_images/1` — how many `<img>` elements an HTML fragment holds
  """

  use Rustler, otp_app: :baudrate, crate: "baudrate_html_parser"

  defmodule OgMetadata do
    @moduledoc "Struct returned by `parse_og_metadata/1`."
    defstruct [:title, :description, :image_url, :site_name]
  end

  @doc """
  Parse an HTML document and extract OG / Twitter Card / fallback metadata.

  Returns a `%OgMetadata{}` struct with `:title`, `:description`, `:image_url`,
  and `:site_name` fields (all `String.t() | nil`).
  """
  @spec parse_og_metadata(String.t()) :: OgMetadata.t()
  def parse_og_metadata(_html), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Every distinct external URL in an HTML fragment, in document order.

  Each `href` is **resolved against `origin` the way a browser resolves it**,
  so `//host/x`, `/\\host/x` and `http:host` count as the links they are, and
  same-site is decided by comparing hosts rather than by string prefix. URLs are
  returned resolved and without their fragment, so two links to one page count
  once. Fragment-only links, links classed `hashtag` or `mention`, and anything
  that does not resolve to http(s) are skipped.
  """
  @spec extract_urls(String.t(), String.t()) :: [String.t()]
  def extract_urls(_html, _origin), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  The first external URL in an HTML fragment, by the rules of `extract_urls/2`.

  Returned as written when it is already an absolute http(s) URL — a link
  preview then shows what the author typed rather than its punycode — and
  resolved otherwise. Returns `nil` when there is none.
  """
  @spec extract_first_url(String.t(), String.t()) :: String.t() | nil
  def extract_first_url(_html, _origin), do: :erlang.nif_error(:nif_not_loaded)

  @doc "The number of `<img>` elements in an HTML fragment."
  @spec count_images(String.t()) :: non_neg_integer()
  def count_images(_html), do: :erlang.nif_error(:nif_not_loaded)
end
