defmodule Baudrate.Bots.FeedParserNative do
  @moduledoc """
  Rustler NIF bindings to the `baudrate_feed_parser` Rust crate.

  Wraps the [`feedparser-rs`](https://github.com/bug-ops/feedparser-rs) library
  which supports RSS 2.0, RSS 1.0 (RDF), Atom 1.0, and JSON Feed formats.

  The single public function `parse_feed/1` accepts raw feed bytes and returns a
  list of `Entry` structs with raw (unsanitized) field values.  Post-processing
  (HTML sanitization, title normalization, date clamping) is handled by
  `Baudrate.Bots.FeedParser`.
  """

  use Rustler, otp_app: :baudrate, crate: "baudrate_feed_parser"

  defmodule Entry do
    @moduledoc "Raw feed entry returned by the `baudrate_feed_parser` NIF."

    @type t :: %__MODULE__{
            id: String.t() | nil,
            title: String.t() | nil,
            link: String.t() | nil,
            content: String.t() | nil,
            summary: String.t() | nil,
            tags: [String.t()],
            published_rfc3339: String.t() | nil
          }

    defstruct [:id, :title, :link, :content, :summary, tags: [], published_rfc3339: nil]
  end

  @doc """
  Parse a feed from raw bytes.

  Accepts RSS 2.0, RSS 1.0 (RDF), Atom 1.0, and JSON Feed.

  Returns `{:ok, [%Entry{}]}` on success or `{:error, reason}` on parse failure.
  """
  @spec parse_feed(binary()) :: {:ok, [Entry.t()]} | {:error, String.t()}
  def parse_feed(_data), do: :erlang.nif_error(:nif_not_loaded)
end
