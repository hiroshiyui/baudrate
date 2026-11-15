defmodule BaudrateWeb.ShareTargetController do
  @moduledoc """
  Handles PWA Web Share Target POST requests.

  When the user shares text from another app into the installed PWA, the OS
  sends a POST to `/share` with `title`, `text`, and/or `url` parameters.
  This controller checks session authentication and redirects to
  `/articles/new` with query params to pre-fill the article form.

  If the user is not authenticated, the intended destination is stored in
  the cookie session as `:return_to` and the user is redirected to `/login`.
  After successful login, `SessionController.establish_session/3` consumes
  the stored path and redirects there.

  ## Security

  - No CSRF token required (OS POST has none) — uses the `:share_target`
    pipeline which omits `:protect_from_forgery`
  - Parameters are truncated to prevent abuse: title (200 chars),
    text (64 KB), url (2048 chars)
  - Only local paths starting with `/` are stored in `:return_to`
  - A request another site made (`Sec-Fetch-Site: cross-site`/`same-site`) is
    sent home without touching the session
  """

  use BaudrateWeb, :controller

  alias Baudrate.Auth

  @max_title_length 200
  @max_text_length 65_536
  @max_url_length 2048

  @doc """
  Receives shared content from the OS and redirects to the article creation form.

  If authenticated, redirects to `/articles/new?title=...&text=...&url=...`.
  If not authenticated, stores the target path in `:return_to` and redirects to `/login`.
  """
  def create(conn, params) do
    if cross_site?(conn) do
      # Never write the session for a request another site made. The route
      # is CSRF-exempt and the cookie is `SameSite=Lax`, so a cross-site POST
      # arrives without it: writing `:return_to` used to answer with a fresh
      # cookie holding nothing else, which replaced the member's session — a
      # forced logout — and pre-filled their next composer with the other
      # site's text. A share from the installed app is `none` or
      # `same-origin`; a browser that sends no fetch metadata is let through.
      # `ignore: true` because the pipeline has already written one key
      # (`SetLocale` stores the locale), and any cookie at all replaces theirs.
      conn
      |> configure_session(ignore: true)
      |> redirect(to: "/")
    else
      handle_share(conn, params)
    end
  end

  defp cross_site?(conn) do
    get_req_header(conn, "sec-fetch-site") in [["cross-site"], ["same-site"]]
  end

  defp handle_share(conn, params) do
    title = truncate_param(params["title"], @max_title_length)
    text = truncate_param(params["text"], @max_text_length)
    url = truncate_param(params["url"], @max_url_length)

    query =
      %{}
      |> maybe_put("title", title)
      |> maybe_put("text", text)
      |> maybe_put("url", url)

    target_path =
      case URI.encode_query(query) do
        "" -> "/articles/new"
        qs -> "/articles/new?" <> qs
      end

    session_token = get_session(conn, :session_token)

    case session_token && Auth.get_user_by_session_token(session_token) do
      {:ok, _user} ->
        redirect(conn, to: target_path)

      _ ->
        conn
        |> put_session(:return_to, target_path)
        |> redirect(to: "/login")
    end
  end

  defp truncate_param(nil, _max), do: ""
  defp truncate_param(val, max) when is_binary(val), do: String.slice(val, 0, max)
  defp truncate_param(_val, _max), do: ""

  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
