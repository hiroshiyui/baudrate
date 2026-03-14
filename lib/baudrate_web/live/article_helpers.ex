defmodule BaudrateWeb.ArticleHelpers do
  @moduledoc """
  Pure helper functions for `BaudrateWeb.ArticleLive`.

  Extracted to reduce the size of the LiveView module and allow isolated
  testing of logic that does not require a LiveView process. Includes poll
  display helpers (used from the template via `import BaudrateWeb.ArticleHelpers`),
  permission guards, comment tree building, and federation vote scheduling.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Baudrate.Content
  alias BaudrateWeb.RateLimits

  @doc """
  Returns `:ok` if the user is allowed to forward an article, or `{:error, :rate_limited}`.

  Admins bypass the rate limit.
  """
  def check_forward_rate_limit(%{role: %{name: "admin"}}), do: :ok

  def check_forward_rate_limit(user) do
    case RateLimits.check_create_article(user.id) do
      :ok -> :ok
      {:error, :rate_limited} -> {:error, :rate_limited}
    end
  end

  @doc """
  Returns true if the given user may view the article.

  An article with no boards is always visible. Otherwise at least one board
  must be visible to the user.
  """
  def user_can_view_article?(article, _user) when article.boards == [], do: true

  def user_can_view_article?(article, user) do
    Enum.any?(article.boards, &Content.can_view_board?(&1, user))
  end

  @doc """
  Splits a flat list of comments into `{roots, children_map}`.

  `roots` is the list of top-level comments (no `parent_id`).
  `children_map` maps each parent ID to its list of direct children.
  """
  def build_comment_tree(comments) do
    roots = Enum.filter(comments, &is_nil(&1.parent_id))

    children_map =
      comments
      |> Enum.filter(& &1.parent_id)
      |> Enum.group_by(& &1.parent_id)

    {roots, children_map}
  end

  @doc """
  Assigns poll-related data to the socket from the article's poll association.

  Assigns: `:poll`, `:user_votes`, `:has_voted`, `:poll_closed`.
  """
  def assign_poll_data(socket, article, current_user) do
    poll = article.poll

    if poll do
      user_votes =
        if current_user,
          do: Content.get_user_poll_votes(poll.id, current_user.id),
          else: []

      socket
      |> assign(:poll, poll)
      |> assign(:user_votes, user_votes)
      |> assign(:has_voted, user_votes != [])
      |> assign(:poll_closed, Baudrate.Content.Poll.closed?(poll))
    else
      socket
      |> assign(:poll, nil)
      |> assign(:user_votes, [])
      |> assign(:has_voted, false)
      |> assign(:poll_closed, false)
    end
  end

  @doc """
  Extracts the selected vote option IDs from the cast_vote form params.

  Handles both single-choice (`vote_option`) and multi-choice (`vote_options[]`) polls.
  """
  def extract_vote_option_ids(params, poll) do
    case poll.mode do
      "single" ->
        case params["vote_option"] do
          nil -> []
          id -> parse_int_list([id])
        end

      "multiple" ->
        (params["vote_options"] || [])
        |> List.wrap()
        |> parse_int_list()
    end
  end

  @doc """
  Schedules federation delivery of a poll vote for remote articles.

  Only federated when the article has a `remote_actor_id` (i.e., the article
  originated on a remote instance).
  """
  def schedule_federation_vote(user, article, poll, option_ids) do
    if article.remote_actor_id do
      poll = Content.preload_poll_options(poll)

      voted_options =
        poll.options
        |> Enum.filter(&(&1.id in option_ids))

      Content.schedule_federation_task(fn ->
        Baudrate.Federation.Publisher.publish_vote(user, article, voted_options)
      end)
    end
  end

  @doc """
  Returns the percentage (0.0–100.0) of votes for an option.

  Returns `0` when `total` is zero to avoid division by zero.
  """
  def poll_percentage(_votes_count, 0), do: 0

  def poll_percentage(votes_count, total) do
    Float.round(votes_count / total * 100, 1)
  end

  @doc """
  Returns the total number of votes cast across all poll options.
  """
  def total_votes(poll) do
    Enum.sum(Enum.map(poll.options, & &1.votes_count))
  end

  # --- Private ---

  defp parse_int_list(strings) do
    Enum.flat_map(strings, fn s ->
      case Integer.parse(s) do
        {n, ""} -> [n]
        _ -> []
      end
    end)
  end
end
