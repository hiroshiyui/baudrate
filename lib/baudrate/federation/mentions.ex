defmodule Baudrate.Federation.Mentions do
  @moduledoc """
  Turns the `@user@domain` handles in a piece of local text into the actors
  they name, and into the `Mention` tags and addressing an ActivityPub object
  carries (ADR 0051).

  `Baudrate.Content.Markdown` owns the *syntax* — what a handle looks like —
  and deliberately knows nothing about who exists. This module owns the
  *reference*: which handles name an actor we can reach, and what to do when
  one does not.

  ## Two entry points, and the difference matters

    * `warm/2` runs **once, when the content is written**, and may make
      outbound WebFinger and actor fetches to learn an actor nobody here has
      seen. It is rate limited per user and capped per post, because each
      unknown handle costs another server two requests and the text is
      attacker-chosen. It is called *before* the write transaction, never
      inside it — an HTTP call in a transaction holds a database connection
      open for the length of somebody else's timeout (ADR 0034).

    * `known/1` runs **every time the object is built**, and only reads the
      database. It never fetches. So serving `/ap/articles/:slug` costs one
      indexed query per render rather than a network round trip, and the
      object a peer fetches is identical to the one that was published.

  The split is why an unresolvable handle degrades silently: `warm/2` tried,
  `known/1` finds nothing, the handle stays plain text and the post goes out
  without it. That is the documented behaviour (P3-D2), not a swallowed error.

  ## What a mention may not do

  A mention **addresses**; it never widens the audience (P3-D3). Callers apply
  [ADR 0043](../../../doc/adr/0043-the-outbound-federation-gate-and-withdrawals.md)'s
  board gate *before* asking for tags or recipients, so an article in a
  private or AP-disabled board produces no `Mention` tag, no `cc` entry and no
  delivery job however many handles it contains. Otherwise typing a handle
  would be a one-step way to send a private board's article to any instance on
  the internet.
  """

  import Ecto.Query

  alias Baudrate.Content.Markdown
  alias Baudrate.Federation
  alias Baudrate.Federation.{Discovery, DomainBlocks, RemoteActor}
  alias Baudrate.Repo
  alias BaudrateWeb.RateLimits

  require Logger

  # At most this many *unknown* handles in one post trigger a lookup. The
  # per-user hourly limit bounds the sustained rate; this bounds the burst, so
  # a single post with fifty handles cannot make fifty servers receive a
  # request at once. Handles past the cap are simply not resolved — if one of
  # them is already known it still tags, because that costs nothing.
  @lookup_cap 8

  # Per-lookup and whole-step deadlines, in milliseconds. A member is watching
  # a spinner while this runs, and the federation defaults (30 s per read, 60 s
  # whole-request, twice — WebFinger then the actor) would hold a post for
  # minutes on a single mistyped handle. A healthy server answers both in well
  # under a second; one that does not simply loses the tag.
  @lookup_timeout 3_000
  @total_budget 5_000

  @doc """
  Splits the handles in `text` into local usernames and remote `{user, domain}`
  pairs.

  A handle naming **this** instance's own host is a local mention written the
  long way, and is returned as local — otherwise `@alice@our.host` would be
  looked up over the network to find a row we already have, and would federate
  as a `Mention` of ourselves.
  """
  @spec extract(String.t() | nil) :: %{local: [String.t()], remote: [{String.t(), String.t()}]}
  def extract(text) do
    host = local_host()

    {ours, theirs} =
      text
      |> Markdown.extract_remote_mentions()
      |> Enum.split_with(fn {_user, domain} -> domain == host end)

    %{
      local: Enum.uniq(Markdown.extract_mentions(text) ++ Enum.map(ours, &elem(&1, 0))),
      remote: theirs
    }
  end

  @doc """
  Resolves any remote handles in `text` that this instance does not already
  know, so that `known/1` can find them afterwards.

  Returns `:ok` always. A handle that does not resolve — no WebFinger, a
  blocked domain, a rate limit reached, a server that is down — leaves no
  trace and no error: the mention stays plain text, which is what the author
  sees locally too.

  Call this **before** the transaction that writes the content.
  """
  @spec warm(String.t() | nil, integer() | nil) :: :ok
  def warm(text, user_id) do
    case unknown_handles(text) do
      [] ->
        :ok

      handles ->
        if allowed?(user_id) do
          deadline = System.monotonic_time(:millisecond) + @total_budget
          handles |> Enum.take(@lookup_cap) |> Enum.each(&lookup(&1, deadline))
        else
          Logger.info("federation.mention_resolve_throttled: user_id=#{inspect(user_id)}")
        end

        :ok
    end
  end

  @doc """
  Returns the remote actors named by the handles in `text`, without fetching.

  Excludes actors on a blocked domain and suspended actors: a mention is an
  addressing decision, and addressing an instance we have blocked would send
  it our content and hand it the reply (ADR 0030 decision 9 — a block stops us
  reaching out, not only listening).
  """
  @spec known(String.t() | nil) :: [RemoteActor.t()]
  def known(text) do
    case extract(text).remote do
      [] -> []
      handles -> handles |> fetch_rows() |> Enum.reject(&DomainBlocks.actor_hidden?(&1.id))
    end
  end

  @doc """
  Builds the `Mention` tags for an object from the actors `known/1` returned.

  `name` carries the full `@user@domain` handle, which is what Mastodon
  renders and what it matches against `href` when it re-links the mention in
  its own display.
  """
  @spec tags([RemoteActor.t()]) :: [map()]
  def tags(actors) do
    Enum.map(actors, fn actor ->
      %{
        "type" => "Mention",
        "href" => actor.ap_id,
        "name" => "@#{actor.username}@#{actor.domain}"
      }
    end)
  end

  @doc """
  The actor URIs to add to an object's `cc`, so the mentioned actors are
  genuinely addressed rather than merely named in a tag.
  """
  @spec uris([RemoteActor.t()]) :: [String.t()]
  def uris(actors), do: Enum.map(actors, & &1.ap_id)

  @doc """
  The inboxes to deliver to, preferring a shared inbox.
  """
  @spec inboxes([RemoteActor.t()]) :: [String.t()]
  def inboxes(actors) do
    actors
    |> Enum.flat_map(fn
      %{shared_inbox: shared} when is_binary(shared) and shared != "" -> [shared]
      %{inbox: inbox} when is_binary(inbox) and inbox != "" -> [inbox]
      _ -> []
    end)
    |> Enum.uniq()
  end

  # --- Private ---

  defp unknown_handles(text) do
    case extract(text).remote do
      [] ->
        []

      handles ->
        have =
          handles
          |> fetch_rows()
          |> MapSet.new(&{String.downcase(&1.username), &1.domain})

        Enum.reject(handles, &MapSet.member?(have, &1))
    end
  end

  # One query for every handle in the post, not one per handle. `domain` is
  # stored downcased (`RemoteActor.changeset/2`); `username` is not, so it is
  # folded in SQL — two instances' actors can differ only by case and a
  # mention has to reach the right one.
  defp fetch_rows(handles) do
    conditions =
      Enum.reduce(handles, false, fn {user, domain}, acc ->
        dynamic([a], ^acc or (fragment("lower(?)", a.username) == ^user and a.domain == ^domain))
      end)

    Repo.all(from(a in RemoteActor, where: ^conditions))
  end

  # The budget is checked before each lookup rather than enforced across them:
  # a lookup already in flight keeps its own 3 s, so the worst case for a post
  # is the budget plus one timeout, not the budget times the cap.
  defp lookup({user, domain}, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      Logger.info("federation.mention_budget_spent: handle=#{user}@#{domain}")
      :ok
    else
      do_lookup({user, domain})
    end
  end

  defp do_lookup({user, domain}) do
    case Discovery.lookup_remote_actor("#{user}@#{domain}", timeout: @lookup_timeout) do
      {:ok, _actor} ->
        :ok

      {:error, reason} ->
        # Info, not warning: a handle that does not resolve is an ordinary
        # typo, and the author is told nothing either (P3-D2).
        Logger.info("federation.mention_unresolved: handle=#{user}@#{domain} #{inspect(reason)}")
        :ok
    end
  end

  # No user means no budget to spend against, and no caller that should be
  # making outbound requests — a bot's feed body is not a place to resolve
  # mentions from.
  defp allowed?(nil), do: false

  defp allowed?(user_id) do
    RateLimits.check_mention_resolve(user_id) == :ok
  end

  defp local_host do
    Federation.base_url() |> URI.parse() |> Map.get(:host) |> to_string() |> String.downcase()
  end
end
