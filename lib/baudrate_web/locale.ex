defmodule BaudrateWeb.Locale do
  @moduledoc """
  Which language a request renders in, and where that answer is kept.

  ## Locale Resolution Priority

    1. The `locale` **cookie** — an explicit choice, made in the footer
       switcher (`BaudrateWeb.LocaleController`). It is first because it is the
       only one of these a person actually said out loud.
    2. The member's `preferred_locales`, cached into the session at login
       (`SessionController`). Only a session write can refresh that copy, so
       `LocaleController` rewrites it whenever the list changes — see its
       moduledoc.
    3. The `Accept-Language` header, parsed by `BaudrateWeb.Plugs.SetLocale`.
    4. The default Gettext locale (`"en"`).

  `SetLocale` walks that list for a normal request; `BaudrateWeb.AuthHooks`
  reads the answer back out of the session, so a LiveView mount does not flip
  the language after the dead render.

  ## The cookie

  A named, one-year cookie rather than a key in the session, because the
  session is dropped at sign-out (`configure_session(drop: true)`) and expires
  in fourteen days — a preference kept there would reset itself, silently, and
  look like a bug in the switcher. It is `http_only` because nothing in the
  browser needs to read it, and `secure` is set explicitly here for the reason
  `BaudrateWeb.Endpoint`'s moduledoc records: inferring it from `conn.scheme`
  makes it depend on a proxy sending `x-forwarded-proto`.

  The instance sets exactly two cookies; `doc/development.md` lists both.

  ## Functions

    * `resolve_from_preferences/1` — first known locale in a list, or `nil`
    * `known?/1` — the allow-list; no unchecked string reaches Gettext
    * `auto/0` — the sentinel for "I have no choice; follow my account, then
      my browser", which is what makes the switcher reversible
    * `locale_display_name/1`, `available_locales/0` — for rendering it
  """

  @display_names %{
    "en" => "English",
    "ja_JP" => "日本語",
    "zh_TW" => "台灣漢語"
  }

  @auto "auto"
  @cookie_name "locale"
  @cookie_max_age 365 * 24 * 60 * 60

  # `secure:` is decided at compile time from the environment, exactly as
  # `BaudrateWeb.Endpoint` decides it for the session cookie. Dev and test stay
  # without it so cookies work over plain HTTP on localhost.
  @cookie_attributes [same_site: "Lax", http_only: true, secure: Mix.env() == :prod]

  @doc """
  Returns the first locale from `locales` that is a known Gettext locale, or `nil`.
  """
  def resolve_from_preferences(locales) when is_list(locales) do
    Enum.find(locales, &known?/1)
  end

  def resolve_from_preferences(_), do: nil

  @doc """
  Is this string a locale this instance actually has translations for?

  The allow-list. Everything that reaches `Gettext.put_locale/1` from a cookie,
  a form field or a database column passes through here first, so an unknown
  value is ignored rather than carried around as a locale that renders nothing.
  """
  def known?(code) when is_binary(code), do: code in Gettext.known_locales(BaudrateWeb.Gettext)
  def known?(_), do: false

  @doc """
  The sentinel value meaning "no explicit choice".

  Posting it to `BaudrateWeb.LocaleController` deletes the cookie, which hands
  the decision back to the account and then to `Accept-Language`. A switcher
  with no way back to automatic is a one-way door.
  """
  def auto, do: @auto

  @doc "Name of the cookie holding an explicit language choice."
  def cookie_name, do: @cookie_name

  @doc "Options for `Plug.Conn.put_resp_cookie/4` when storing the choice."
  def cookie_options, do: [{:max_age, @cookie_max_age} | @cookie_attributes]

  @doc """
  Options for `Plug.Conn.delete_resp_cookie/3`.

  The attributes have to match the ones the cookie was written with, or the
  browser keeps the old cookie alongside the expired one.
  """
  def cookie_delete_options, do: @cookie_attributes

  @doc """
  Returns a human-readable display name for a locale code.

  Falls back to the code itself if no display name is configured.

  The names are autonyms — each written in its own language, because someone
  looking for Japanese is looking for 日本語, not for the word "Japanese" in a
  language they cannot read. That is also why they are not `gettext`ed.

  **`zh_TW` is 台灣漢語, never 繁體中文 or 正體中文.** Both of those name a
  *script*, and frame the variety as a typographic variant of something else;
  台灣漢語 names the language as it is spoken and written in Taiwan. The site's
  own governing-language clauses in `doc/eua.md` and `doc/privacy-policy.md`
  already say 台灣漢語, and a switcher that disagreed with them was offering a
  reader a different thing from the one the terms are written in.
  """
  def locale_display_name(code) when is_binary(code) do
    Map.get(@display_names, code, code)
  end

  @doc """
  Returns a list of `{code, display_name}` tuples for all known Gettext locales.
  """
  def available_locales do
    BaudrateWeb.Gettext
    |> Gettext.known_locales()
    |> Enum.map(fn code -> {code, locale_display_name(code)} end)
    |> Enum.sort_by(fn {code, _} -> code end)
  end
end
