defmodule BaudrateWeb.ErrorHTML do
  @moduledoc """
  Renders HTML error pages.

  Templates in `error_html/` are embedded for common status codes
  (404, 500). Any unmatched template falls back to the Phoenix
  plain-text message so new status codes still render something.
  """
  use BaudrateWeb, :html

  embed_templates "error_html/*"

  @doc "Renders a plain-text error page for templates without a dedicated HEEx file."
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
