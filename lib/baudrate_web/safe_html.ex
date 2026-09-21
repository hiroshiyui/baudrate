defmodule BaudrateWeb.SafeHTML do
  @moduledoc """
  Renders stored, already-sanitized HTML.

  Use this instead of a bare `raw/1` for any `body_html` column. Two passes run
  on the way out:

    * `Baudrate.Media.Rewriter` — so a remote `<img>` stored before the media
      proxy existed, or written by any future ingest path that forgets to proxy,
      still never reaches the viewer's browser as a third-party request.
    * `BaudrateWeb.ImageAltFallback` — so an `<img>` with no description is
      announced rather than skipped. `alt=""` claims the image is decorative
      (ADR 0061), and the fallback is translated, which only has a correct
      answer once there is a reader to translate for.

  Applying both at render rather than at ingest is what makes them
  backfill-free: every existing row is covered, the canonical remote URL is
  preserved so a failed fetch stays retryable, and the stored HTML keeps saying
  what the peer or the member actually wrote.

  The input must already have passed through `Baudrate.Sanitizer.Native`. This
  function does not sanitize.
  """

  @doc "Rewrites remote images in stored HTML and marks it safe for rendering."
  @spec body_html(String.t() | nil) :: Phoenix.HTML.safe()
  def body_html(nil), do: Phoenix.HTML.raw("")

  # sobelow_skip ["XSS.Raw"]
  def body_html(html) when is_binary(html) do
    html
    |> Baudrate.Media.Rewriter.rewrite_img_src()
    |> BaudrateWeb.ImageAltFallback.fill()
    |> Phoenix.HTML.raw()
  end

  # sobelow_skip ["XSS.Raw"]
  def body_html(other), do: Phoenix.HTML.raw(other)

  @doc """
  Renders a Markdown column and marks it safe.

  The companion to `body_html/1` for the columns that are stored as Markdown
  and rendered on the way out — an article's body, a comment with no
  `body_html`, a profile signature, the policy documents.

  `Baudrate.Content.Markdown.to_html/1` already ends with the Ammonia
  sanitizer and the media-proxy rewrite, so its output is the allow-listed HTML
  `raw/1` requires. What it cannot do is the accessible-name fallback: it lives
  in the Content context and the fallback is translated, so it belongs on this
  side of the boundary. Routing both kinds of column through this module is
  what keeps the two render-time passes travelling together — the media proxy
  and the `alt` fallback are applied to the same strings by the same layer,
  rather than one of them reaching only half the pages.
  """
  @spec markdown(String.t() | nil) :: Phoenix.HTML.safe()
  # sobelow_skip ["XSS.Raw"]
  def markdown(text) do
    text
    |> Baudrate.Content.Markdown.to_html()
    |> BaudrateWeb.ImageAltFallback.fill()
    |> Phoenix.HTML.raw()
  end
end
