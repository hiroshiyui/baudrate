defmodule BaudrateWeb.ErrorHTML do
  @moduledoc """
  Renders HTML error pages.

  Templates in `error_html/` are embedded for common status codes
  (404, 500). Any unmatched template falls back to the Phoenix
  plain-text message so new status codes still render something.
  """
  use BaudrateWeb, :html

  embed_templates "error_html/*"

  @doc """
  Returns the localized document title for an error page status code.

  Error pages are rendered by `Phoenix.Endpoint.RenderErrors` into the root
  layout with fixed assigns (`:status`, `:kind`, `:reason`, `:stack`), so a
  template cannot set `:page_title` itself. The root layout calls this with
  `assigns[:status]` when no `:page_title` is present, giving every error page
  a meaningful `<title>` (WCAG 2.4.2). Returns `nil` for anything else so
  regular pages are unaffected.
  """
  @spec page_title(term()) :: String.t() | nil
  def page_title(404), do: gettext("Page not found")

  def page_title(status) when is_integer(status) and status >= 500,
    do: gettext("Something went wrong")

  def page_title(_), do: nil

  @doc "Renders a plain-text error page for templates without a dedicated HEEx file."
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
