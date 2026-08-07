defmodule BaudrateWeb.SafeHTML do
  @moduledoc """
  Renders stored, already-sanitized HTML.

  Use this instead of a bare `raw/1` for any `body_html` column. It applies
  `Baudrate.Media.Rewriter` on the way out, so a remote `<img>` stored before the
  media proxy existed — or written by any future ingest path that forgets to
  proxy — still never reaches the viewer's browser as a third-party request.

  Applying it at render rather than at ingest is what makes the proxy
  backfill-free: every existing row is covered, and the canonical remote URL is
  preserved so a failed fetch stays retryable.

  The input must already have passed through `Baudrate.Sanitizer.Native`. This
  function does not sanitize.
  """

  @doc "Rewrites remote images in stored HTML and marks it safe for rendering."
  @spec body_html(String.t() | nil) :: Phoenix.HTML.safe()
  def body_html(nil), do: Phoenix.HTML.raw("")

  def body_html(html) when is_binary(html) do
    html
    |> Baudrate.Media.Rewriter.rewrite_img_src()
    |> Phoenix.HTML.raw()
  end

  def body_html(other), do: Phoenix.HTML.raw(other)
end
