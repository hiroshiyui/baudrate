defmodule BaudrateWeb.PaginationScrollHookTest do
  @moduledoc """
  Every paginated page scrolls back to its list when the page number changes.
  Only the board and search pages used to, so paging the feed left the viewer
  at the bottom of the new page.
  """

  use BaudrateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Baudrate.{Content, Federation, Repo}
  alias Baudrate.Setup.Setting
  alias BaudrateWeb.PaginationScrollHook

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    user = setup_user("user")
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  test "paging the feed scrolls, the initial load and the same page do not", %{
    conn: conn,
    user: user
  } do
    uid = System.unique_integer([:positive])

    actor =
      %Federation.RemoteActor{}
      |> Federation.RemoteActor.changeset(%{
        ap_id: "https://remote.example/users/ps-#{uid}",
        username: "ps_#{uid}",
        domain: "remote.example",
        public_key_pem: "-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----",
        inbox: "https://remote.example/users/ps-#{uid}/inbox",
        actor_type: "Person",
        fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert!()

    {:ok, follow} = Federation.create_user_follow(user, actor)
    {:ok, _} = Federation.accept_user_follow(follow.ap_id)

    for n <- 1..25 do
      {:ok, _} =
        Federation.create_feed_item(%{
          remote_actor_id: actor.id,
          activity_type: "Create",
          object_type: "Note",
          ap_id: "https://remote.example/notes/ps-#{uid}-#{n}",
          body: "Post #{n}",
          body_html: "<p>Post #{n}</p>",
          published_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
    end

    {:ok, lv, _html} = live(conn, "/feed")
    refute_push_event(lv, "scroll-to-top", %{})

    lv |> element(".pagination-page", "2") |> render_click()
    assert_push_event(lv, "scroll-to-top", %{})

    render_patch(lv, "/feed?page=2")
    refute_push_event(lv, "scroll-to-top", %{})

    render_patch(lv, "/feed")
    assert_push_event(lv, "scroll-to-top", %{})
  end

  test "article comment pages scroll to the comments, not the article", %{
    conn: conn,
    user: user
  } do
    board =
      %Content.Board{}
      |> Content.Board.changeset(%{name: "PS", slug: "ps-#{System.unique_integer([:positive])}"})
      |> Repo.insert!()

    {:ok, %{article: article}} =
      Content.create_article(
        %{
          title: "Many comments",
          body: "Body",
          slug: "ps-#{System.unique_integer([:positive])}",
          user_id: user.id
        },
        [board.id]
      )

    for n <- 1..25 do
      {:ok, _} =
        Content.create_comment(%{body: "Comment #{n}", article_id: article.id, user_id: user.id})
    end

    {:ok, lv, _html} = live(conn, "/articles/#{article.slug}")
    assert has_element?(lv, ~s(.pagination-nav[data-scroll-target="comments-section"]))

    lv |> element(".pagination-page", "2") |> render_click()
    assert_push_event(lv, "scroll-to-top", %{})
  end

  test "invalid, missing and first page numbers are the same page" do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}},
      private: %{live_temp: %{}}
    }

    {:cont, socket} = PaginationScrollHook.handle_params(%{}, "/", socket)
    {:cont, socket} = PaginationScrollHook.handle_params(%{"page" => "1"}, "/", socket)
    {:cont, socket} = PaginationScrollHook.handle_params(%{"page" => "junk"}, "/", socket)
    assert Map.get(socket.private.live_temp, :push_events, []) == []

    {:cont, socket} = PaginationScrollHook.handle_params(%{"page" => "3"}, "/", socket)
    assert [["scroll-to-top", %{}]] = socket.private.live_temp.push_events
  end
end
