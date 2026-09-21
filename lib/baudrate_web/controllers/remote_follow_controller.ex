defmodule BaudrateWeb.RemoteFollowController do
  @moduledoc """
  Hands a fediverse visitor to their own instance to follow someone here.

  ## Why a controller and a form, when both pages are LiveViews

  Two reasons, and the second is the load-bearing one.

  CSP is `form-action 'self'`, so the form cannot post straight at the remote
  instance whatever we do — it has to come back here first. Given that, a
  plain `method="post"` form works with scripting switched off, which a
  `phx-submit` does not; the footer language switcher is written the same way
  and for the same reason. It also gives the per-IP limiter a plug to hang on,
  as `:sitemap` and `:share_target` already have.

  ## Why it renders a link rather than redirecting

  This would be the application's first external redirect — nothing in `lib/`
  calls `redirect(external:)` — and `Helpers.local_path/2`, the one
  open-redirect guard, exists to refuse anything that leaves the site.
  Rendering an `<a>` keeps that true, shows the visitor which host they are
  about to hand themselves to before they commit, and avoids browsers
  disagreeing about whether `form-action` applies across a redirect.

  ## What is not taken from the form

  The actor URI. The form carries a **kind and a name** (`user`/`board` plus
  the username or slug) and the controller rebuilds the URI and re-checks
  eligibility, so a posted URI cannot name a board whose page would never have
  offered the control — a non-federated board's actor 404s and its `Follow` is
  `Reject`ed (ADR 0004/0043), so offering it would be a broken promise and an
  existence oracle at once.

  Every failure renders the same page with the same message. Which of them it
  was is information about somebody else's server, and distinguishing them
  turns this into a probe.
  """

  use BaudrateWeb, :controller

  alias Baudrate.Auth
  alias Baudrate.Content
  alias Baudrate.Content.Board
  alias Baudrate.Federation
  alias Baudrate.Federation.RemoteFollow
  alias Baudrate.Setup
  alias BaudrateWeb.RateLimits

  def create(conn, params) do
    handle = params["handle"] || ""

    case target(params) do
      {:ok, kind, name, label} ->
        resolve(conn, handle, Federation.actor_uri(kind, name), label)

      :error ->
        raise BaudrateWeb.NotFoundError
    end
  end

  defp resolve(conn, handle, actor_uri, label) do
    with {:ok, {_user, domain}} <- RemoteFollow.parse_handle(handle),
         :ok <- RateLimits.check_remote_follow_domain(domain),
         {:ok, url} <- RemoteFollow.subscribe_url(handle, actor_uri) do
      render(conn, :show,
        page_title: gettext("Follow from your instance"),
        noindex: true,
        subscribe_url: url,
        destination: URI.parse(url).host,
        handle: handle,
        target_label: label
      )
    else
      _ ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:show,
          page_title: gettext("Follow from your instance"),
          noindex: true,
          subscribe_url: nil,
          destination: nil,
          handle: handle,
          target_label: label
        )
    end
  end

  # The eligibility rules, applied here rather than trusted from the page that
  # rendered the form.
  defp target(%{"type" => "user", "name" => username}) when is_binary(username) do
    with true <- Setup.federation_enabled?(),
         %{status: status} = user when status != "banned" <- Auth.get_user_by_username(username),
         # A moved account is a redirect elsewhere; the local Follow button is
         # already hidden for one, so this must not offer what that withholds.
         nil <- Baudrate.AccountMigration.moved_target(user) do
      {:ok, :user, user.username, "@" <> user.username}
    else
      _ -> :error
    end
  end

  defp target(%{"type" => "board", "name" => slug}) when is_binary(slug) do
    with true <- Setup.federation_enabled?(),
         %Board{} = board <- Content.get_board_by_slug(slug),
         # `federated?/1`, never `ap_enabled` alone: a members-only board with
         # AP switched on has an actor that answers 404 (ADR 0043).
         true <- Board.federated?(board) do
      {:ok, :board, board.slug, board.name}
    else
      _ -> :error
    end
  end

  defp target(_), do: :error
end
