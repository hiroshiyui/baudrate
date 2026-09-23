defmodule BaudrateWeb.PrivacySettingsLiveTest do
  @moduledoc """
  The pages of ADR 0073's settings: `/profile/privacy`'s controls, the
  muted-words collapse where a post is shown, follow requests on
  `/followers` and the Requested button, and `noindex` for a member who
  opted out of discovery.
  """

  use BaudrateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Baudrate.{Auth, Content, Federation, Repo}
  alias Baudrate.Content.Board
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    member = setup_user("user")

    board =
      Repo.insert!(
        Board.changeset(%Board{}, %{name: "B", slug: "b-#{System.unique_integer([:positive])}"})
      )

    Repo.update_all(Board, set: [min_role_to_view: "guest"])

    %{conn: log_in_user(conn, member), member: member, board: board}
  end

  defp article(user, board, title, body) do
    {:ok, %{article: article}} =
      Content.create_article(
        %{
          title: title,
          body: body,
          slug: "a-#{System.unique_integer([:positive])}",
          user_id: user.id
        },
        [board.id]
      )

    article
  end

  describe "/profile/privacy" do
    test "mutes and unmutes a server", %{conn: conn, member: member} do
      {:ok, lv, _html} = live(conn, "/profile/privacy")

      lv
      |> form("#profile-muted-domain-form", domain_mute: %{domain: "https://Loud.Example/@x"})
      |> render_submit()

      assert has_element?(lv, "#profile-muted-domains-list", "loud.example")
      [mute] = Auth.list_muted_domains(member)

      lv |> element("#muted-domain-unmute-#{mute.id}") |> render_click()
      assert Auth.list_muted_domains(member) == []
    end

    test "a refused server keeps what was typed and says why", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/profile/privacy")

      html =
        lv
        |> form("#profile-muted-domain-form", domain_mute: %{domain: "not a domain"})
        |> render_submit()

      assert html =~ "must be a domain name"
      assert has_element?(lv, ~s(#profile-muted-domain-input[value="not a domain"]))
    end

    test "adds and removes a muted word", %{conn: conn, member: member} do
      {:ok, lv, _html} = live(conn, "/profile/privacy")

      lv
      |> form("#profile-muted-word-form", muted_word: %{pattern: "Spoiler", kind: "word"})
      |> render_submit()

      assert Repo.reload!(member).muted_keywords == [%{"kind" => "word", "pattern" => "spoiler"}]
      assert has_element?(lv, "#muted-word-0", "spoiler")

      lv |> element("#muted-word-remove-0") |> render_click()
      assert Repo.reload!(member).muted_keywords == []
    end

    test "switches approval and discoverability", %{conn: conn, member: member} do
      {:ok, lv, _html} = live(conn, "/profile/privacy")

      lv |> element("#profile-approve-followers") |> render_click()
      assert Repo.reload!(member).manually_approves_followers

      lv |> element("#profile-discoverable") |> render_click()
      refute Repo.reload!(member).discoverable
    end
  end

  describe "the muted-words collapse" do
    test "folds someone else's post, and never the member's own", ctx do
      other = setup_user("user")
      theirs = article(other, ctx.board, "About the finale", "big spoiler inside")
      mine = article(ctx.member, ctx.board, "My spoiler", "my own words")

      {:ok, _} =
        Auth.update_muted_keywords(ctx.member, [%{"kind" => "word", "pattern" => "spoiler"}])

      {:ok, lv, _html} = live(ctx.conn, "/articles/#{theirs.slug}")
      assert has_element?(lv, "details#article-#{theirs.id}-muted", "Hidden by your muted words")
      # Never names the word that matched.
      refute has_element?(lv, "#article-#{theirs.id}-muted summary", "spoiler")

      {:ok, lv, _html} = live(ctx.conn, "/articles/#{mine.slug}")
      refute has_element?(lv, "#article-#{mine.id}-muted")

      {:ok, lv, _html} = live(ctx.conn, "/boards/#{ctx.board.slug}")
      assert has_element?(lv, "details#article-#{theirs.slug}-muted")
      # Collapsed, not removed: both posts are still listed.
      assert has_element?(lv, "#article-#{theirs.slug}")
      assert has_element?(lv, "#article-#{mine.slug}")
    end

    test "a guest sees nothing collapsed", ctx do
      other = setup_user("user")
      theirs = article(other, ctx.board, "Finale", "spoiler")

      {:ok, _} =
        Auth.update_muted_keywords(ctx.member, [%{"kind" => "word", "pattern" => "spoiler"}])

      {:ok, lv, _html} = live(build_conn(), "/articles/#{theirs.slug}")
      refute has_element?(lv, "#article-#{theirs.id}-muted")
    end
  end

  describe "follow requests" do
    test "a request waits on /followers and is approved there", ctx do
      {:ok, _} = Auth.update_manually_approves_followers(ctx.member, true)
      asker = setup_user("user")
      {:ok, _} = Federation.create_local_follow(asker, Repo.reload!(ctx.member))

      {:ok, lv, _html} = live(ctx.conn, "/followers")
      assert has_element?(lv, "#follow-request-local-#{asker.id}")

      lv |> element("#follow-request-approve-local-#{asker.id}") |> render_click()

      assert Federation.local_follow_state(asker.id, ctx.member.id) == "accepted"
      refute has_element?(lv, "#follow-request-local-#{asker.id}")
      assert has_element?(lv, "#follow-requests-status", "approved")
    end

    test "the profile's button says Requested until then", %{conn: conn} do
      target = setup_user("user")
      {:ok, _} = Auth.update_manually_approves_followers(target, true)

      {:ok, lv, _html} = live(conn, "/users/#{target.username}")
      lv |> element("#user-profile-follow") |> render_click()

      assert has_element?(lv, "#user-profile-follow-requested", "Follow Requested")
      refute has_element?(lv, "#user-profile-unfollow")
    end
  end

  describe "opting out of discovery" do
    test "the profile and the member's articles are noindex, and still readable", ctx do
      {:ok, _} = Auth.update_discoverable(ctx.member, false)
      article = article(ctx.member, ctx.board, "Readable", "still here")

      profile = build_conn() |> get("/users/#{ctx.member.username}") |> html_response(200)
      assert profile =~ ~s(<meta name="robots" content="noindex)

      page = build_conn() |> get("/articles/#{article.slug}") |> html_response(200)
      assert page =~ ~s(<meta name="robots" content="noindex)
      assert page =~ "still here"
    end
  end
end
