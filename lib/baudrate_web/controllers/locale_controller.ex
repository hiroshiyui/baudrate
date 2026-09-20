defmodule BaudrateWeb.LocaleController do
  @moduledoc """
  Changes the language a browser renders the site in.

  The footer switcher posts here (`POST /locale`). It is a plain form, not a
  LiveView event, for two reasons: writing a cookie and the session is a
  controller's job in this codebase (the `phx-trigger-action` pattern), and a
  language control has to keep working when scripting has gone wrong — the same
  judgement that makes a content warning a `<details>` and not a hook
  (ADR 0052). Nothing here needs JavaScript.

  ## What a request may say

  Two shapes, and nothing else is honoured:

    * a locale `BaudrateWeb.Locale.known?/1` accepts — stored in the cookie;
    * `BaudrateWeb.Locale.auto/0` — the cookie is deleted, handing the decision
      back to the account and then to `Accept-Language`.

  Any other value changes nothing at all: no error page, no flash, no atom
  created from the input, and the value is never echoed back into the response.
  A switcher is not a place to report a typo — the only way to send one is to
  forge the form.

  `return_to` goes through `BaudrateWeb.Helpers.local_path/2`, the one
  open-redirect guard, so a forged field cannot bounce a visitor off-site.

  ## Why it also writes the session

  `BaudrateWeb.Plugs.SetLocale` reads a member's language out of
  `session[:preferred_locales]`, which `SessionController` writes **at login
  and nowhere else**. Changing languages on `/profile` writes the database, and
  a LiveView cannot write the session, so that copy went stale: every later
  full page load rendered its dead HTML — including `lang=` on `<html>` — in
  the old language, and kept doing it until the member signed in again. A
  screen reader was told the wrong language on every page load.

  So every request through here refreshes `session[:preferred_locales]` from
  the saved user, unconditionally, whatever the locale param said. That is the
  fix, and `ProfileLive` posts here after a language change for exactly this.
  """

  use BaudrateWeb, :controller

  alias Baudrate.Auth
  alias BaudrateWeb.Helpers
  alias BaudrateWeb.Locale

  @doc """
  Stores an explicit language choice and returns to the page it came from.
  """
  def update(conn, params) do
    conn
    |> apply_choice(params["locale"])
    |> sync_session_preferences()
    |> redirect(to: return_path(conn, params["return_to"]))
  end

  # The path comes from the form field, which CSRF protection covers. The query
  # string cannot: `AuthHooks.attach_current_path_hook/1` assigns the path
  # alone, so switching language on `/search?q=…` or `?page=3` would drop the
  # reader back at the top of an unfiltered first page.
  #
  # `referer` has the whole URL, but it is a header and not something to
  # navigate on by itself. So it is used for the query string **only**, and
  # only when it is same-origin and its path is the one the form already
  # named — the destination is still decided by the field.
  defp return_path(conn, return_to) do
    path = Helpers.local_path(return_to, "/")

    case referer_uri(conn) do
      %URI{path: ^path, query: query} when is_binary(query) and query != "" ->
        path <> "?" <> query

      _ ->
        path
    end
  end

  defp referer_uri(conn) do
    with [referer] <- get_req_header(conn, "referer"),
         %URI{host: host} = uri when host == conn.host <- URI.parse(referer) do
      uri
    else
      _ -> nil
    end
  end

  # A member's click is also a statement about their account, so the chosen
  # language moves to the head of the ordered list `/profile` renders. Without
  # this the footer and the profile page would disagree, and the choice would
  # not survive to another device.
  defp apply_choice(conn, locale) do
    cond do
      locale == Locale.auto() ->
        conn
        |> delete_resp_cookie(Locale.cookie_name(), Locale.cookie_delete_options())
        |> promote_for_member(nil)

      Locale.known?(locale) ->
        conn
        |> put_resp_cookie(Locale.cookie_name(), locale, Locale.cookie_options())
        |> promote_for_member(locale)

      true ->
        conn
    end
  end

  defp promote_for_member(conn, nil), do: conn

  defp promote_for_member(conn, locale) do
    case current_user(conn) do
      nil ->
        conn

      user ->
        current = user.preferred_locales || []
        # A validation failure is not worth an error page here: the cookie is
        # already set, so the switcher did what the reader asked. The sync
        # below re-reads whatever was actually saved, so the session cannot
        # end up describing a list the database does not hold.
        _ = Auth.update_preferred_locales(user, [locale | List.delete(current, locale)])
        conn
    end
  end

  # Re-reads the account's list so the session copy `SetLocale` consults
  # matches the database again. Runs for every request, including the ones
  # whose locale param was ignored, because `ProfileLive` posts here after a
  # change the switcher itself did not make.
  defp sync_session_preferences(conn) do
    case current_user(conn) do
      nil -> conn
      user -> put_session(conn, :preferred_locales, user.preferred_locales || [])
    end
  end

  defp current_user(conn) do
    with token when is_binary(token) <- get_session(conn, :session_token),
         {:ok, user} <- Auth.get_user_by_session_token(token) do
      user
    else
      _ -> nil
    end
  end
end
