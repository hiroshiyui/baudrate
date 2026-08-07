defmodule Baudrate.Media.Rewriter do
  @moduledoc """
  Rewrites remote `<img src>` in already-sanitized HTML to proxied paths.

  Applied at render time rather than at ingest, which means it also covers every
  row stored before the proxy existed — no backfill, and the canonical remote URL
  is never destroyed, so a failed fetch is retryable instead of permanent.

  ## Why a regex is sufficient here

  This only ever runs on output from `Baudrate.Sanitizer.Native`, whose Ammonia
  serializer emits double-quoted, entity-escaped attribute values and drops any
  `src` that is not `https://`, `http://`, `/uploads/`, or `/media/`. The input
  space is therefore closed, and the pass is idempotent: an already-rewritten
  `/media/...` src does not match.

  Never run this on unsanitized HTML.
  """

  alias Baudrate.Media.Proxy

  # Captures the src value of an <img> whose URL is absolute or protocol-relative.
  @img_src_re ~r/(<img\b[^>]*?\bsrc=")((?:https?:)?\/\/[^"]*)(")/i

  @doc """
  Rewrites every remote `<img src>` to its proxied path.

  Passes `nil` and blank input through, and leaves local paths and `<a href>`
  untouched.
  """
  @spec rewrite_img_src(String.t() | nil) :: String.t() | nil
  def rewrite_img_src(nil), do: nil
  def rewrite_img_src(""), do: ""

  def rewrite_img_src(html) when is_binary(html) do
    Regex.replace(@img_src_re, html, fn _full, prefix, url, suffix ->
      proxied =
        url
        |> unescape_attr()
        |> Proxy.url()
        |> escape_attr()

      prefix <> proxied <> suffix
    end)
  end

  def rewrite_img_src(other), do: other

  # Attribute values arrive HTML-escaped (`&amp;` in query strings, most
  # commonly). Sign the real URL, not the escaped form, or the signature will
  # not match what the controller decodes.
  defp unescape_attr(value) do
    value
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
  end

  defp escape_attr(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
