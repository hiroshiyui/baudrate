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

  # Any element that *fetches* something, pointing at an absolute (http/https)
  # or protocol-relative URL. `<a href>` is navigation, not a subresource, so
  # it is deliberately absent.
  #
  # This matched only `<img>` until v1.29.x, which is how a YouTube `<iframe>`
  # lived on article, comment and DM pages for months without the gate
  # noticing: the invariant is about subresources, and the test was about
  # images.
  @subresource_tags ~w(img iframe script source video audio embed track object input)
  @hotlink_re ~r/<(?:#{Enum.join(@subresource_tags, "|")})[^>]+(?:src|data)="(?:https?:)?\/\//
  # A `<link>` fetches only for some `rel` values. `alternate` and `canonical`
  # are metadata — an article's `rel="alternate"` legitimately points at the
  # remote original's `ap_id`, on the host that published it, and the browser
  # never requests it.
  @fetching_rels ~w(stylesheet preload modulepreload prefetch prerender icon apple-touch-icon manifest)
  @link_tag_re ~r/<link[^>]*>/
  # url(...) inside an inline style or a <style> block.
  @css_hotlink_re ~r/url\(\s*['"]?(?:https?:)?\/\//

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
           "#{where} rendered a third-party subresource: " <>
             inspect(Regex.run(@hotlink_re, html))

    for tag <- Regex.scan(@link_tag_re, html) |> List.flatten() do
      refute fetching_link?(tag) and Regex.match?(~r/href="(?:https?:)?\/\//, tag),
             "#{where} rendered a third-party fetching <link>: #{inspect(tag)}"
    end

    refute Regex.match?(@css_hotlink_re, html),
           "#{where} rendered a third-party url() in CSS: " <>
             inspect(Regex.run(@css_hotlink_re, html))
  end

  defp fetching_link?(tag) do
    case Regex.run(~r/rel="([^"]+)"/, tag) do
      [_, rel] -> rel |> String.split() |> Enum.any?(&(&1 in @fetching_rels))
      nil -> false
    end
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

  describe "the YouTube link preview" do
    test "renders a local poster and no player until the reader asks", %{conn: conn} do
      user = setup_user("user")
      b = board()

      preview =
        %Content.LinkPreview{}
        |> Content.LinkPreview.changeset(%{url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"})
        |> Repo.insert!()
        |> Content.LinkPreview.fetched_changeset(%{
          title: "A Video",
          status: "fetched",
          image_url: "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
          image_path: "/uploads/link_previews/local-thumb.webp"
        })
        |> Repo.update!()

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "Watch this",
            body: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            slug: "yt-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          [b.id]
        )

      article
      |> Ecto.Changeset.change(link_preview_id: preview.id)
      |> Repo.update!()

      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, "/articles/#{article.slug}")

      assert_no_hotlink(html, "article with a YouTube link")

      # The whole point of click-to-load: nothing addressed to Google is in the
      # document. The player is built by the hook, on the click.
      refute html =~ "<iframe", "the YouTube player was rendered before the reader asked for it"
      refute html =~ "youtube-nocookie.com"

      # And the poster really did render, so the assertions above are not
      # passing because the fixture never reached the page.
      assert html =~ "link-preview-video-play"
      assert html =~ ~s(src="/uploads/link_previews/local-thumb.webp")
      assert html =~ "YouTubeEmbedHook"
    end
  end

  test "the CSP admits exactly one embed origin", %{conn: conn} do
    [csp] =
      conn
      |> get(~p"/")
      |> get_resp_header("content-security-policy")

    [frame_src] =
      csp
      |> String.split(";")
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&String.starts_with?(&1, "frame-src"))

    assert frame_src == "frame-src https://www.youtube-nocookie.com",
           """
           The embed allow-list changed. Every origin here can see the IP and
           User-Agent of every reader whose page carries one of its embeds, so
           adding a second is a decision for an ADR, not a CSP edit
           (ADR 0006, ADR 0045).

           Found: #{frame_src}
           """
  end
end
