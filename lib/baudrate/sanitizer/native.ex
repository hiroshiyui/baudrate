defmodule Baudrate.Sanitizer.Native do
  @moduledoc """
  Rustler NIF bindings to the `baudrate_sanitizer` Rust crate.

  Provides three HTML sanitization functions backed by
  [Ammonia](https://github.com/rust-ammonia/ammonia) (html5ever parser):

    * `sanitize_federation/1` — allowlist for incoming AP content
    * `sanitize_markdown/1` — allowlist for local Markdown rendering
    * `strip_tags/1` — strip all HTML tags, preserving text content
  """

  use Rustler, otp_app: :baudrate, crate: "baudrate_sanitizer"

  @doc "Sanitize incoming federation HTML with a strict allowlist."
  @spec sanitize_federation(String.t()) :: String.t()
  def sanitize_federation(_html), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Sanitize Earmark-rendered Markdown HTML with a permissive allowlist."
  @spec sanitize_markdown(String.t()) :: String.t()
  def sanitize_markdown(_html), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Strip all HTML tags, preserving only text content."
  @spec strip_tags(String.t()) :: String.t()
  def strip_tags(_html), do: :erlang.nif_error(:nif_not_loaded)
end
