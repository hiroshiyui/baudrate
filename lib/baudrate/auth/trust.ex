defmodule Baudrate.Auth.Trust do
  # Fixed by P5-D2: what an account that has not yet earned trust may put in
  # one post, and how often it may post.
  @links_per_post 1
  @images_per_post 1
  @posts_per_hour 10

  # The thresholds are settings, so an operator can raise them during a wave.
  @default_days 3
  @default_posts 3
  @max_days 30
  @max_posts 20

  @moduledoc """
  Whether an account has outgrown the limits on new accounts (P5-D2, ADR 0064).

  ## Earned, and decided at the moment of asking

  An account is **trusted** once it is `new_account_days` old *and* has
  `new_account_posts` articles and comments that are still up — #{@default_days}
  and #{@default_posts} unless an admin changes them. Both are read from the
  clock and a count when the question is asked, and nothing is stored. ADR 0029
  refuses a background job that lifts a sanction, because a missed run holds
  someone past their time; a `trusted` flag flipped by a sweep would do the same
  to a new member who had already earned their way out. It also means trust is
  *lost* with the posts that earned it: a moderator who removes a spammer's
  three warm-up comments takes it back.

  Trusted whatever their age:

    * **bots** — a bot has no age worth the name and holds no conversations,
      and an RSS item routinely carries several links, so a limit that did not
      exempt them would stop every feed the moment it was switched on. ADR 0031
      found exactly that for the terms gate, and the answer is the same: the
      exemption lives here, in the predicate, not in its callers.
    * **admins and moderators**, by role.

  An invite confers nothing. That is the case the invite-chain ban (ADR 0063)
  exists for.

  Counted: local articles and comments that are not soft-deleted. A reply to a
  remote timeline item is **not** counted — no moderator here can remove one,
  so it cannot be a post that was "not removed", and counting it would let an
  account earn trust where nobody on this site is looking.

  ## What an untrusted account may do

    * at most #{@links_per_post} external link and #{@images_per_post} image in
      a post. Links are counted by resolving every `href` the way a browser
      does (`Baudrate.HtmlParser.Native.extract_urls/2`): `//host` and `/\\host`
      leave the site as surely as `https://host`, and a count that read the
      attribute as text would miss them. Images are the attached uploads plus
      any in the body.
    * at most #{@posts_per_hour} posts an hour, articles, comments and timeline
      replies together — one bucket, checked here, so a new path to post cannot
      forget it the way a per-page limit could be forgotten.
    * direct messages only to people who follow it, who have written to it
      first, or who are staff. That rule lives in `Baudrate.Messaging`, which
      asks `trusted?/1`.
    * **no new link or image in its signature** (`check_signature/3`). A
      signature is shown under every article the account posts, so even one
      link there would double what each post may carry.

  ## An edit is a second way in

  Posting clean and editing dirty thirty seconds later would walk round every
  limit on creation, so edits are checked too — with one difference. An edit
  may not **add** a link or an image past the limit, but it never has to
  remove one that is already there: a member who posted before the limits
  were switched on, or whose post an admin edited, must still be able to fix a
  typo. A link is "added" when the edited post links somewhere the old one did
  not; an image when the count goes up.

  ## Switching it off

  `0` for both settings trusts everyone. The test suite runs that way
  (`config/test.exs`), and tests about the limits turn them on.
  """

  import Ecto.Query

  alias Baudrate.Content.Markdown
  alias Baudrate.HtmlParser.Native, as: HtmlParser
  alias Baudrate.Repo
  alias Baudrate.Setup
  alias Baudrate.Setup.User

  @staff_roles ~w(admin moderator)

  @typedoc "Why a new account's post or message was refused."
  @type refusal ::
          :new_account_links
          | :new_account_images
          | :new_account_rate_limited
          | :new_account_dm
          | :new_account_signature

  @typedoc """
  An account's standing. `post_count` is counted only as far as
  `posts_required`, so it is never larger than the number that matters.
  `old_enough_at` is when the account reaches `days_required`, and is `nil`
  for an account nobody needs to wait on.
  """
  @type standing :: %{
          trusted: boolean(),
          days_required: non_neg_integer(),
          posts_required: non_neg_integer(),
          post_count: non_neg_integer(),
          old_enough_at: DateTime.t() | nil
        }

  @doc "What an untrusted account may put in one post, and how often it may post."
  @spec limits() :: %{
          links: pos_integer(),
          images: pos_integer(),
          posts_per_hour: pos_integer()
        }
  def limits,
    do: %{links: @links_per_post, images: @images_per_post, posts_per_hour: @posts_per_hour}

  @doc "The largest values the two settings accept."
  @spec max_thresholds() :: %{days: pos_integer(), posts: pos_integer()}
  def max_thresholds, do: %{days: @max_days, posts: @max_posts}

  @doc """
  The two thresholds, `%{days: n, posts: n}`.

  Each setting wins; with no setting, the application default applies
  (#{@default_days} and #{@default_posts} in production, 0 in the test suite so
  that tests which are not about trust are not made to earn it). Values are
  clamped to 0..#{@max_days} and 0..#{@max_posts}.
  """
  @spec thresholds() :: %{days: non_neg_integer(), posts: non_neg_integer()}
  def thresholds do
    %{
      days: threshold("new_account_days", :new_account_days, @default_days, @max_days),
      posts: threshold("new_account_posts", :new_account_posts, @default_posts, @max_posts)
    }
  end

  defp threshold(key, env_key, default, max) do
    case Setup.get_setting(key) do
      nil -> Application.get_env(:baudrate, env_key, default)
      value -> parse(value, default)
    end
    |> max(0)
    |> min(max)
  end

  defp parse(value, _default) when is_integer(value), do: value

  defp parse(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} -> n
      _ -> default
    end
  end

  defp parse(_, default), do: default

  @doc """
  The account's standing: whether it is trusted, and if not, how far it has to
  go. Takes a `User` (or anything with an integer `id`), a user id, or `nil`.

  One query. An unknown id and `nil` are trusted — there is no account to
  limit, and the caller's own existence checks decide what that means, as
  `Baudrate.Auth.ensure_can_interact/1` does.
  """
  @spec standing(User.t() | map() | integer() | nil) :: standing()
  def standing(%{id: id}) when is_integer(id), do: standing(id)

  def standing(user_id) when is_integer(user_id) do
    %{days: days, posts: posts} = thresholds()

    if days == 0 and posts == 0 do
      trusted_standing(days, posts)
    else
      user_id
      |> load(posts)
      |> to_standing(days, posts)
    end
  end

  def standing(_), do: trusted_standing(0, 0)

  defp trusted_standing(days, posts),
    do: %{
      trusted: true,
      days_required: days,
      posts_required: posts,
      post_count: posts,
      old_enough_at: nil
    }

  # The two counts stop at the threshold (`LIMIT`), so asking about a member
  # with ten thousand comments costs no more than asking about a new one.
  defp load(user_id, posts) do
    from(u in User,
      left_join: r in assoc(u, :role),
      where: u.id == ^user_id,
      select: %{
        is_bot: u.is_bot,
        role: r.name,
        inserted_at: u.inserted_at,
        post_count:
          fragment(
            """
            (SELECT count(*) FROM (SELECT 1 FROM articles
               WHERE user_id = ? AND deleted_at IS NULL LIMIT ?) AS counted_articles)
            + (SELECT count(*) FROM (SELECT 1 FROM comments
               WHERE user_id = ? AND deleted_at IS NULL LIMIT ?) AS counted_comments)
            """,
            u.id,
            ^posts,
            u.id,
            ^posts
          )
      }
    )
    |> Repo.one()
  end

  defp to_standing(nil, days, posts), do: trusted_standing(days, posts)

  defp to_standing(%{is_bot: true}, days, posts), do: trusted_standing(days, posts)

  defp to_standing(%{role: role}, days, posts) when role in @staff_roles,
    do: trusted_standing(days, posts)

  defp to_standing(row, days, posts) do
    old_enough_at = DateTime.add(row.inserted_at, days * 86_400, :second)
    post_count = min(row.post_count, posts)
    old_enough? = DateTime.compare(DateTime.utc_now(), old_enough_at) != :lt

    %{
      trusted: old_enough? and post_count >= posts,
      days_required: days,
      posts_required: posts,
      post_count: post_count,
      old_enough_at: if(old_enough?, do: nil, else: old_enough_at)
    }
  end

  @doc """
  How many local articles and comments `user_id` has that are not
  soft-deleted, counted only as far as `limit` — the count trust is earned
  by, which `Baudrate.Moderation.HeldPosts` also asks when it decides whether
  a post is one of an account's first (ADR 0065).
  """
  @spec count_posts(integer(), non_neg_integer()) :: non_neg_integer()
  def count_posts(_user_id, 0), do: 0

  def count_posts(user_id, limit) when is_integer(user_id) and is_integer(limit) do
    count =
      Repo.one(
        from(u in User,
          where: u.id == ^user_id,
          select:
            fragment(
              """
              (SELECT count(*) FROM (SELECT 1 FROM articles
                 WHERE user_id = ? AND deleted_at IS NULL LIMIT ?) AS counted_articles)
              + (SELECT count(*) FROM (SELECT 1 FROM comments
                 WHERE user_id = ? AND deleted_at IS NULL LIMIT ?) AS counted_comments)
              """,
              u.id,
              ^limit,
              u.id,
              ^limit
            )
        )
      )

    min(count || 0, limit)
  end

  @doc "Whether the account has outgrown the limits on new accounts."
  @spec trusted?(User.t() | map() | integer() | nil) :: boolean()
  def trusted?(user), do: standing(user).trusted

  @doc "Whether `user` is an admin or a moderator."
  @spec staff?(User.t() | map() | nil) :: boolean()
  def staff?(%{role: %{name: name}}) when is_binary(name), do: name in @staff_roles

  def staff?(%{id: id}) when is_integer(id) do
    Repo.exists?(
      from(u in User,
        join: r in assoc(u, :role),
        where: u.id == ^id and r.name in @staff_roles
      )
    )
  end

  def staff?(_), do: false

  @doc """
  Checks a post by `user` against the limits on new accounts: `:ok` for a
  trusted account, otherwise `:ok` or `{:error, refusal}`.

  `body` is the Markdown as written; it is rendered only when the account is
  untrusted, so a trusted member's post costs one query here and nothing more.
  `image_count` is the number of attached uploads; images written into the
  body are added to it.

  A new post also takes a place in the hourly bucket, and only once it has
  passed the other two checks, so a post refused for its links does not use
  one up.

  ## Options

    * `:previous` — `{body, image_count}` as the post stood before, which makes
      this an **edit**: nothing already there has to go, nothing may be added
      past the limit, and the hourly bucket is not touched.
  """
  @spec check_post(
          User.t() | map() | integer() | nil,
          String.t() | nil,
          non_neg_integer(),
          keyword()
        ) :: :ok | {:error, refusal()}
  def check_post(user, body, image_count, opts \\ []) do
    if trusted?(user) do
      :ok
    else
      counted = count(body, image_count)

      case Keyword.fetch(opts, :previous) do
        {:ok, {old_body, old_image_count}} ->
          check_edit(counted, count(old_body, old_image_count))

        :error ->
          check_new(counted, user_id(user))
      end
    end
  end

  @doc """
  Checks a signature change by `user`: `:ok` for a trusted account, and for
  an untrusted one unless `signature` links somewhere `previous` did not or
  holds more images than it did (`{:error, :new_account_signature}`).

  The allowance is none rather than a post's one, because a signature is
  rendered under every article the account posts. Like an edit, it never has
  to remove what is already there.
  """
  @spec check_signature(User.t() | map() | integer() | nil, String.t() | nil, String.t() | nil) ::
          :ok | {:error, refusal()}
  def check_signature(user, signature, previous) do
    if trusted?(user) do
      :ok
    else
      %{links: links, images: images} = count(signature, 0)
      %{links: old_links, images: old_images} = count(previous, 0)

      if links -- old_links == [] and images <= old_images,
        do: :ok,
        else: {:error, :new_account_signature}
    end
  end

  defp count(body, image_count) do
    html = Markdown.to_html(body || "")

    %{
      links: HtmlParser.extract_urls(html, BaudrateWeb.Endpoint.url()),
      images: image_count + HtmlParser.count_images(html)
    }
  end

  defp check_new(%{links: links, images: images}, user_id) do
    cond do
      length(links) > @links_per_post -> {:error, :new_account_links}
      images > @images_per_post -> {:error, :new_account_images}
      true -> take_hourly_place(user_id)
    end
  end

  defp check_edit(%{links: links, images: images}, %{links: old_links, images: old_images}) do
    cond do
      length(links) > @links_per_post and links -- old_links != [] ->
        {:error, :new_account_links}

      images > @images_per_post and images > old_images ->
        {:error, :new_account_images}

      true ->
        :ok
    end
  end

  defp take_hourly_place(nil), do: :ok

  defp take_hourly_place(user_id) do
    case BaudrateWeb.RateLimits.check_new_account_post(user_id) do
      :ok -> :ok
      {:error, :rate_limited} -> {:error, :new_account_rate_limited}
    end
  end

  defp user_id(%{id: id}) when is_integer(id), do: id
  defp user_id(id) when is_integer(id), do: id
  defp user_id(_), do: nil
end
