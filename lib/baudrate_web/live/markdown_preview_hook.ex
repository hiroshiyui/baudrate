defmodule BaudrateWeb.MarkdownPreviewHook do
  @moduledoc """
  LiveView `attach_hook` that handles `"markdown_preview"` events.

  When a user toggles the markdown preview, the JS hook sends the textarea
  content via `pushEvent`. This hook intercepts the event, renders the
  markdown server-side using `Content.Markdown.to_html/1` (ensuring consistent
  sanitization), and replies with the rendered HTML directly to the JS caller.

  Uses the `{:halt, reply, socket}` pattern so the JS `pushEvent` reply
  callback receives the result immediately.

  Attach this hook in `on_mount` callbacks via `attach(socket)`.
  """

  import Phoenix.LiveView

  @max_body_bytes 64 * 1024

  @doc """
  Attaches the `:markdown_preview` handle_event hook to the socket.

  Returns the socket unchanged if the lifecycle system is not initialized
  (e.g. in unit tests with bare `%Socket{}`).
  """
  def attach(%{private: %{lifecycle: _}} = socket) do
    attach_hook(socket, :markdown_preview, :handle_event, &handle_event/3)
  end

  def attach(socket), do: socket

  defp handle_event("markdown_preview", %{"body" => body}, socket)
       when byte_size(body) > @max_body_bytes do
    {:halt, %{error: "body_too_large"}, socket}
  end

  defp handle_event("markdown_preview", %{"body" => body}, socket) do
    html = Baudrate.Content.Markdown.to_html(body)
    {:halt, %{html: html}, socket}
  end

  defp handle_event(_event, _params, socket) do
    {:cont, socket}
  end
end
