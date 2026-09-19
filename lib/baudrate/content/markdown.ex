defmodule Baudrate.Content.Markdown do
  @moduledoc """
  Converts Markdown text to sanitized HTML using MDEx.

  The rendering pipeline is:

  1. **Block normalization** — inserts blank lines between consecutive HTML
     block elements so the parser treats each as a separate HTML block. Required
     for bot articles whose bodies are stored as sanitized HTML rather than
     Markdown (e.g. RSS feed content where paragraphs abut with no blank lines).
  2. **MDEx** — Markdown → raw HTML (CommonMark + GFM tables/strikethrough/
     autolink/tasklist, `render: [unsafe: true]` so stored HTML passes through)
  3. **Ammonia sanitizer** — strips unsafe HTML tags/attributes
  4. **Media rewriting** — rewrites remote `<img src>` to the local media proxy
     so rendering never discloses the viewer's IP to a third-party host
  5. **Hashtag linkification** — converts `#tag` to clickable links
  6. **Mention linkification** — converts `@username` to a local profile link and
     `@user@domain` to a search link that resolves the remote actor here

  Raw HTML is rendered unescaped (step 2) *because* step 3 is the security gate:
  every rendered document is passed through the Ammonia allowlist before it is
  ever stored or displayed. The sanitizer only allows `href` on `<a>` tags. By
  running linkification *after* sanitization, the injected `<a>` tags are never
  stripped. Tag names and usernames are regex-validated so no injection is possible.

  Step 4 likewise runs *after* sanitization, because it relies on Ammonia having
  already narrowed `img[src]` to a closed set of forms (see
  `Baudrate.Media.Rewriter`).
  """

  @mdex_opts [
    extension: [table: true, strikethrough: true, autolink: true, tasklist: true],
    render: [unsafe: true]
  ]

  @skip_re ~r/<(pre|code|a)[\s>].*?<\/\1>/su
  @hashtag_re ~r/(?:^|(?<=\s|[^\w&]))#(\p{L}[\w]{0,63})/u

  # A local mention is a bare `@name`, 3–32 characters, matching what
  # `Setup.User` allows. The trailing `(?![\w@])` is what keeps it from
  # swallowing the first half of a fediverse handle: without it
  # `@alice@mastodon.social` matched `@alice` — `@` satisfies `[^\w]` — and
  # linkified it to the *local* `/users/alice`, silently pointing a mention of
  # a remote person at whoever holds that name here.
  @local_mention_re ~r/(?:^|(?<=\s|[^\w]))@([a-zA-Z0-9_]{3,32})(?![\w@])/u

  # A remote mention is `@user@domain`. The local part is 1–32 rather than
  # 3–32, because the length rule is the *other* instance's to set. The domain
  # is ASCII labels plus a 2+ letter TLD, which is what a punycoded IDN handle
  # looks like by the time it reaches us. Requiring the domain here is also
  # what keeps an ordinary email address out: `bob@example.com` has no leading
  # `@`, and the lookbehind refuses a match that starts mid-word.
  @remote_mention_re ~r/(?:^|(?<=\s|[^\w]))@([a-zA-Z0-9_]{1,32})@((?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63})(?![\w@-])/u

  @doc """
  Renders a Markdown string to sanitized HTML with linkified hashtags and mentions.

  Returns an empty string for `nil` or blank input.

  ## Examples

      iex> Baudrate.Content.Markdown.to_html("**bold**")
      "<p><strong>bold</strong></p>"

      iex> Baudrate.Content.Markdown.to_html(nil)
      ""
  """
  @spec to_html(String.t() | nil) :: String.t()
  def to_html(nil), do: ""
  def to_html(""), do: ""

  def to_html(text) when is_binary(text) do
    text
    |> normalize_html_blocks()
    |> MDEx.to_html!(@mdex_opts)
    |> sanitize_html()
    |> Baudrate.Media.Rewriter.rewrite_img_src()
    |> linkify_hashtags()
    |> linkify_mentions()
  end

  defp sanitize_html(html) do
    Baudrate.Sanitizer.Native.sanitize_markdown(html)
  end

  # Inserts blank lines between consecutive block-level HTML elements so that
  # the Markdown parser treats each as a separate HTML block. Without this, HTML
  # content stored by syndication bots (where paragraphs are adjacent with no blank
  # lines) causes the parser to drop all paragraphs after the first.
  defp normalize_html_blocks(text) do
    text
    |> String.trim()
    |> then(
      &Regex.replace(
        ~r{</(p|div|blockquote|h[1-6]|ul|ol|li|pre|table|thead|tbody|tr)>},
        &1,
        "</\\1>\n\n"
      )
    )
    |> String.trim()
  end

  @doc false
  def linkify_hashtags(html) do
    parts = Regex.split(@skip_re, html, include_captures: true)

    Enum.map(parts, fn part ->
      if Regex.match?(~r/\A<(pre|code|a)[\s>]/s, part) do
        part
      else
        Regex.replace(@hashtag_re, part, fn full, tag ->
          prefix = String.slice(full, 0, String.length(full) - String.length(tag) - 1)
          downcased = String.downcase(tag)
          ~s[#{prefix}<a href="/tags/#{downcased}" class="hashtag">##{tag}</a>]
        end)
      end
    end)
    |> Enum.join()
  end

  @doc false
  def linkify_mentions(html) do
    # Unwrap first, then remote, then local. Both linkify passes skip text
    # already inside `<pre>`, `<code>` or `<a>`, so the links the remote pass
    # writes are out of the local pass's reach.
    html
    |> unwrap_autolinked_handles()
    |> outside_skipped(&replace_remote_mentions/1)
    |> outside_skipped(&replace_local_mentions/1)
  end

  # MDEx's `autolink` extension turns `alice@example.com` into a `mailto:`
  # link in step 2, so by the time mentions are linkified a fediverse handle
  # has *already* been wrapped in an `<a>` — which the skip pass then leaves
  # alone, rendering `@` followed by a mailto link to an address that is not
  # an address. Undo exactly that shape: an autolink whose href is
  # `mailto:<text>`, whose text is the whole address, and which is immediately
  # preceded by `@`. An email address written without a leading `@` never
  # matches, so ordinary autolinked mail stays a mailto link.
  defp unwrap_autolinked_handles(html) do
    Regex.replace(~r|@<a href="mailto:([^"]*)"[^>]*>([^<]*)</a>|, html, fn full, addr, text ->
      if addr == text and handle?(text), do: "@" <> text, else: full
    end)
  end

  defp handle?(text) do
    case Regex.run(@remote_mention_re, "@" <> text) do
      [matched | _] -> matched == "@" <> text
      _ -> false
    end
  end

  defp outside_skipped(html, fun) do
    @skip_re
    |> Regex.split(html, include_captures: true)
    |> Enum.map(fn part ->
      if Regex.match?(~r/\A<(pre|code|a)[\s>]/s, part), do: part, else: fun.(part)
    end)
    |> Enum.join()
  end

  defp replace_local_mentions(part) do
    Regex.replace(@local_mention_re, part, fn full, username ->
      prefix = String.slice(full, 0, String.length(full) - String.length(username) - 1)
      downcased = String.downcase(username)
      ~s[#{prefix}<a href="/users/#{downcased}" class="mention">@#{username}</a>]
    end)
  end

  # A remote handle links to this site's own search, which resolves it to the
  # actor and offers a follow (`SearchLive`). Not to `https://domain/@user`:
  # that is a guess at another server's URL scheme, wrong for Lemmy and
  # others, and it would put an off-site link in every mention. The handle is
  # matched by a regex that admits only `[A-Za-z0-9_]` and hostname
  # characters, so there is nothing to escape.
  defp replace_remote_mentions(part) do
    Regex.replace(@remote_mention_re, part, fn full, user, domain ->
      handle = "#{user}@#{domain}"
      prefix = String.slice(full, 0, String.length(full) - String.length(handle) - 1)
      query = URI.encode_www_form("@" <> handle)

      ~s[#{prefix}<a href="/search?q=#{query}" class="mention mention-remote">@#{handle}</a>]
    end)
  end

  @doc """
  Extracts unique downcased bare `@username` mentions from raw markdown text.

  Local mentions only — `@alice@example.com` is a *remote* handle and is
  returned by `extract_remote_mentions/1` instead, never split into a local
  `alice` here.

  Operates on raw markdown (before HTML conversion). Fenced code blocks and
  inline code are stripped before matching to avoid false positives.

  ## Examples

      iex> Baudrate.Content.Markdown.extract_mentions("Hello @Alice and @bob")
      ["alice", "bob"]

      iex> Baudrate.Content.Markdown.extract_mentions("Hi @alice@example.com")
      []

      iex> Baudrate.Content.Markdown.extract_mentions(nil)
      []
  """
  @spec extract_mentions(String.t() | nil) :: [String.t()]
  def extract_mentions(nil), do: []
  def extract_mentions(""), do: []

  def extract_mentions(text) when is_binary(text) do
    text
    |> strip_code_blocks()
    |> then(&Regex.scan(@local_mention_re, &1, capture: :all_but_first))
    |> List.flatten()
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  @doc """
  Extracts unique `@user@domain` mentions as `{user, domain}` tuples.

  Both halves are downcased: a handle is compared against
  `remote_actors.username` and `.domain`, and the domain column is stored
  downcased for exactly this kind of comparison.

  This is the syntactic half only — whether a handle names anybody is
  `Baudrate.Federation.Mentions`'s question, and this module deliberately does
  not ask it. Rendering must not depend on the network or the database.

  ## Examples

      iex> Baudrate.Content.Markdown.extract_remote_mentions("Hi @Alice@Example.com")
      [{"alice", "example.com"}]

      iex> Baudrate.Content.Markdown.extract_remote_mentions("mail bob@example.com")
      []
  """
  @spec extract_remote_mentions(String.t() | nil) :: [{String.t(), String.t()}]
  def extract_remote_mentions(nil), do: []
  def extract_remote_mentions(""), do: []

  def extract_remote_mentions(text) when is_binary(text) do
    text
    |> strip_code_blocks()
    |> then(&Regex.scan(@remote_mention_re, &1, capture: :all_but_first))
    |> Enum.map(fn [user, domain] -> {String.downcase(user), String.downcase(domain)} end)
    |> Enum.uniq()
  end

  defp strip_code_blocks(text) do
    text
    |> String.replace(~r/```.*?```/su, "")
    |> String.replace(~r/`[^`]+`/u, "")
  end
end
