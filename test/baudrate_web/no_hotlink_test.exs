defmodule BaudrateWeb.NoHotlinkTest do
  @moduledoc """
  Acceptance gate for the media proxy.

  Baudrate must never emit an `<img>` pointing at a third-party host: doing so
  discloses every viewer's IP address, User-Agent, and reading times to every
  remote instance whose content appears on the page. This test seeds one of each
  hotlinking source that used to exist — remote actor avatars, federated
  attachment images, feed-item attachments, and inline images in a bot/RSS
  article body — renders every page that can display them, and asserts no
  absolute or protocol-relative image URL survives.

  This is what makes `img-src 'self'` safe to enforce, and what stops the
  regression from creeping back in.
  """

  use BaudrateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Baudrate.Content
  alias Baudrate.Federation
  alias Baudrate.Federation.{KeyStore, RemoteActor}
  alias Baudrate.Repo

  # Any src that is absolute (http/https) or protocol-relative.
  @hotlink_re ~r/<img[^>]+src="(?:https?:)?\/\//

  setup do
    Repo.insert!(%Baudrate.Setup.Setting{key: "setup_completed", value: "true"})
    :ok
  end

  defp remote_actor do
    uid = System.unique_integer([:positive])
    {public_pem, _} = KeyStore.generate_keypair()

    Repo.insert!(
      RemoteActor.changeset(%RemoteActor{}, %{
        ap_id: "https://remote.example/users/hot-#{uid}",
        username: "hot_#{uid}",
        domain: "remote.example",
        display_name: "Hotlink Actor",
        avatar_url: "https://remote.example/avatars/#{uid}.png",
        public_key_pem: public_pem,
        inbox: "https://remote.example/users/hot-#{uid}/inbox",
        actor_type: "Person",
        fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
    )
  end

  defp board do
    Repo.insert!(
      Content.Board.changeset(%Content.Board{}, %{
        name: "Hotlink Board",
        slug: "hotlink-#{System.unique_integer([:positive])}",
        ap_enabled: true,
        min_role_to_view: "guest"
      })
    )
  end

  defp assert_no_hotlink(html, where) do
    refute Regex.match?(@hotlink_re, html),
           "#{where} rendered a third-party <img>: " <>
             inspect(Regex.run(~r/<img[^>]*>/, html))
  end

  test "no page renders a third-party <img>", %{conn: conn} do
    user = setup_user("user")
    actor = remote_actor()
    b = board()

    # 1. A remote article (renders the remote actor's avatar).
    {:ok, %{article: remote_article}} =
      Content.create_remote_article(
        %{
          title: "Remote Article",
          body: "Body from elsewhere",
          slug: "remote-hot-#{System.unique_integer([:positive])}",
          ap_id: "https://remote.example/articles/#{System.unique_integer([:positive])}",
          remote_actor_id: actor.id
        },
        [b.id]
      )

    # 2. A local article whose body carries an inline remote image, the shape a
    #    bot/RSS ingest produces.
    {:ok, %{article: bot_article}} =
      Content.create_article(
        %{
          title: "Feed Article",
          body: ~s(<p>Inline</p><p><img src="https://cdn.example/tracker.png" alt="t"></p>),
          slug: "timeline-hot-#{System.unique_integer([:positive])}",
          user_id: user.id
        },
        [b.id]
      )

    # 3. A remote comment whose stored body_html carries a remote image, the
    #    shape rows written before the proxy existed still have.
    {:ok, _comment} =
      Content.create_remote_comment(%{
        body: "Nice",
        body_html: ~s(<p>Nice</p><p><img src="https://remote.example/media/a.png" alt="a"></p>),
        ap_id: "https://remote.example/notes/#{System.unique_integer([:positive])}",
        article_id: remote_article.id,
        remote_actor_id: actor.id
      })

    # 4. A timeline item with remote attachments.
    {:ok, timeline_item} =
      Federation.create_timeline_item(%{
        remote_actor_id: actor.id,
        activity_type: "Create",
        object_type: "Note",
        ap_id: "https://remote.example/notes/feed-#{System.unique_integer([:positive])}",
        body: "Feed body",
        body_html: "<p>Feed body</p>",
        attachments: [
          %{"url" => "https://remote.example/media/att.png", "name" => "att"}
        ],
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    {:ok, follow} = Federation.create_user_follow(user, actor)
    {:ok, _accepted} = Federation.accept_user_follow(follow.ap_id)
    _ = timeline_item

    conn = log_in_user(conn, user)

    pages = [
      {"/", "home"},
      {"/boards/#{b.slug}", "board"},
      {"/articles/#{remote_article.slug}", "remote article"},
      {"/articles/#{bot_article.slug}", "feed article"},
      {"/timeline", "feed"},
      {"/search?q=article", "search"},
      {"/users/#{user.username}", "user profile"}
    ]

    rendered =
      for {path, label} <- pages do
        {:ok, _view, html} = live(conn, path)
        assert_no_hotlink(html, label)
        html
      end

    # Guard against the gate passing vacuously: at least one page must actually
    # have rendered a proxied image, proving the fixtures reached the output.
    assert Enum.any?(rendered, &(&1 =~ ~s(src="/media/))),
           "no page rendered a proxied image — the fixtures are not reaching the templates"
  end
end
