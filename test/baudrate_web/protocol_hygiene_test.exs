defmodule BaudrateWeb.ProtocolHygieneTest do
  @moduledoc """
  Phase 3F: the documents this instance publishes about *itself* say true
  things, and say them in a form a peer can read.

  None of this changes what members see. It changes what a crawler, a
  relay or another server's JSON-LD processor makes of us — which is
  invisible from here and is exactly why it drifted: `localPosts` counted
  articles mirrored from other instances, `users.total` counted feed bots
  and banned accounts, and the `baudrate:*` fields were published without
  being declared in any context, so an expanding consumer dropped them
  silently.
  """

  use BaudrateWeb.ConnCase, async: false

  import Ecto.Query

  alias Baudrate.Content
  alias Baudrate.Content.Board
  alias Baudrate.Federation
  alias Baudrate.Federation.{Context, RemoteActor}
  alias Baudrate.Repo
  alias Baudrate.Setup

  @activity_json "application/activity+json"

  setup do
    Setup.seed_roles_and_permissions()
    Repo.insert!(%Setup.Setting{key: "setup_completed", value: "true"})
    :ok
  end

  describe "NodeInfo counts people and local content" do
    test "bots and banned accounts are not people" do
      _member = create_user()
      _bot = create_user(is_bot: true)
      _banned = create_user(status: "banned")

      assert Federation.nodeinfo()["usage"]["users"]["total"] == 1
    end

    test "localPosts counts local, undeleted articles only" do
      user = create_user()
      board = create_board()

      {:ok, %{article: mine}} = create_article(user, board)
      {:ok, %{article: gone}} = create_article(user, board)
      {:ok, _} = Content.soft_delete_article(gone, deleted_by: user.id)
      create_remote_article(board)

      usage = Federation.nodeinfo()["usage"]

      assert usage["localPosts"] == 1, "a mirrored article is not a local post"
      assert mine.id
    end

    test "localComments follows the same rule" do
      user = create_user()
      board = create_board()
      {:ok, %{article: article}} = create_article(user, board)

      {:ok, _} =
        Content.create_comment(%{
          "body" => "mine",
          "article_id" => article.id,
          "user_id" => user.id
        })

      {:ok, _} =
        Content.create_remote_comment(%{
          body: "theirs",
          body_html: "<p>theirs</p>",
          ap_id: "https://remote.example/notes/#{System.unique_integer([:positive])}",
          article_id: article.id,
          remote_actor_id: create_remote_actor().id
        })

      assert Federation.nodeinfo()["usage"]["localComments"] == 1
    end

    test "active counts come from the sign-in day, not from sessions" do
      recent = create_user()
      old = create_user()
      never = create_user()

      stamp(recent, Date.add(Date.utc_today(), -3))
      stamp(old, Date.add(Date.utc_today(), -90))

      users = Federation.nodeinfo()["usage"]["users"]

      assert users["total"] == 3
      assert users["activeMonth"] == 1
      assert users["activeHalfyear"] == 2

      # An account that has never signed in since the column existed counts as
      # inactive. Under-reporting is the right direction for a statistic other
      # people use to compare instances.
      assert never.last_active_on == nil
    end

    test "signing in stamps the day, and only once", %{} do
      user = create_user()

      {:ok, _token, refresh} = Baudrate.Auth.create_user_session(user.id)
      assert Repo.get!(Setup.User, user.id).last_active_on == Date.utc_today()

      # Backdate, refresh, and confirm the refresh moves it forward.
      stamp(user, Date.add(Date.utc_today(), -2))
      {:ok, _, _} = Baudrate.Auth.refresh_user_session(refresh)
      assert Repo.get!(Setup.User, user.id).last_active_on == Date.utc_today()
    end
  end

  describe "NodeInfo is served at both schema versions" do
    test "the discovery document advertises 2.0 and 2.1" do
      rels =
        build_conn()
        |> get("/.well-known/nodeinfo")
        |> json_response(200)
        |> Map.fetch!("links")
        |> Enum.map(& &1["rel"])

      assert "http://nodeinfo.diaspora.software/ns/schema/2.0" in rels
      assert "http://nodeinfo.diaspora.software/ns/schema/2.1" in rels
    end

    test "2.0 omits software.repository, which its schema has no place for" do
      body = build_conn() |> get("/nodeinfo/2.0") |> json_response(200)

      assert body["version"] == "2.0"
      assert body["software"]["name"] == "baudrate"
      refute Map.has_key?(body["software"], "repository")
    end

    test "2.1 carries it" do
      body = build_conn() |> get("/nodeinfo/2.1") |> json_response(200)

      assert body["version"] == "2.1"
      assert body["software"]["repository"] =~ "baudrate"
    end
  end

  describe "every baudrate: term is declared" do
    test "an article object declares the namespace it uses" do
      user = create_user()
      board = create_board()
      {:ok, %{article: article}} = create_article(user, board)

      object = Federation.article_object(article)

      assert declares_baudrate?(object["@context"]),
             "the object uses baudrate:* terms, so an expanding consumer needs the prefix"

      assert Enum.any?(Map.keys(object), &String.starts_with?(&1, "baudrate:"))
    end

    test "a board actor declares it too" do
      board = create_board()
      {:ok, board} = Baudrate.Federation.KeyStore.ensure_board_keypair(board)

      assert declares_baudrate?(Federation.board_actor(board)["@context"])
    end

    test "an outgoing activity declares it, since the object is embedded" do
      user = create_user()
      board = create_board()
      {:ok, %{article: article}} = create_article(user, board)

      {activity, _} = Federation.Publisher.build_create_article(article)
      assert declares_baudrate?(activity["@context"])
    end

    test "every term the code publishes has a row in the Context documentation" do
      documented =
        Context
        |> Code.fetch_docs()
        |> elem(4)
        |> Map.fetch!("en")

      published =
        Path.wildcard("lib/baudrate/**/*.ex")
        |> Enum.flat_map(fn path ->
          Regex.scan(~r/"(baudrate:[a-zA-Z]+)"/, File.read!(path), capture: :all_but_first)
        end)
        |> List.flatten()
        |> Enum.uniq()
        |> Enum.sort()

      # Without this the check passes when the scan finds nothing, which is
      # how a meta-test quietly stops testing.
      assert length(published) >= 6,
             "scanned #{length(published)} terms, expected the six on file"

      missing = Enum.reject(published, &String.contains?(documented, "`#{&1}`"))

      assert missing == [],
             "these extension terms are published but not documented in " <>
               "Baudrate.Federation.Context: #{Enum.join(missing, ", ")}. " <>
               "A term with no row is one nobody outside this repository can read."
    end
  end

  describe "terms from other vocabularies" do
    # The scan above finds `baudrate:` literals only. A `Person` also carries
    # three terms Mastodon defines (ADR 0073); undeclared, a consumer that
    # expands the document drops them, and with them the member's settings.
    test "the actor context declares manuallyApprovesFollowers, discoverable and indexable" do
      terms =
        Baudrate.Federation.Context.actor()
        |> Enum.filter(&is_map/1)
        |> Enum.reduce(%{}, &Map.merge(&2, &1))

      assert terms["manuallyApprovesFollowers"] == "as:manuallyApprovesFollowers"
      assert terms["as"] == "https://www.w3.org/ns/activitystreams#"
      assert terms["discoverable"] == "toot:discoverable"
      assert terms["indexable"] == "toot:indexable"
      assert terms["toot"] == "http://joinmastodon.org/ns#"
    end
  end

  describe "an actor document may be cached, and only when that is safe" do
    test "a successful actor is cacheable" do
      user = create_user()

      conn =
        build_conn()
        |> put_req_header("accept", @activity_json)
        |> get("/ap/users/#{user.username}")

      assert json_response(conn, 200)
      assert ["public, max-age=" <> _] = get_resp_header(conn, "cache-control")
      assert ["Accept"] = get_resp_header(conn, "vary")
    end

    test "a 404 is never cached — a cached one breaks signature verification" do
      conn =
        build_conn()
        |> put_req_header("accept", @activity_json)
        |> get("/ap/users/nobodyhere")

      assert conn.status == 404
      assert ["no-store"] = get_resp_header(conn, "cache-control")
    end

    test "an HTML redirect is never cached" do
      user = create_user()
      conn = build_conn() |> get("/ap/users/#{user.username}")

      assert redirected_to(conn) == "/"
      assert ["no-store"] = get_resp_header(conn, "cache-control")
    end

    test "authorized fetch turns caching off, because the answer varies by requester" do
      user = create_user()
      Setup.set_setting("ap_authorized_fetch", "true")

      on_exit(fn -> Setup.set_setting("ap_authorized_fetch", "false") end)

      conn =
        build_conn()
        |> put_req_header("accept", @activity_json)
        |> get("/ap/users/#{user.username}")

      # Unsigned, so the plug answers 401 — and whatever the status, a shared
      # cache must not hold this URL: it would serve the document to an
      # unsigned requester and defeat the setting.
      assert conn.status == 401
      refute Enum.any?(get_resp_header(conn, "cache-control"), &String.contains?(&1, "public"))
    end
  end

  # --- helpers ---

  defp declares_baudrate?(context) do
    context
    |> List.wrap()
    |> Enum.any?(fn
      %{} = terms -> Map.has_key?(terms, "baudrate")
      _ -> false
    end)
  end

  defp stamp(user, date) do
    user |> Ecto.Changeset.change(last_active_on: date) |> Repo.update!()
  end

  defp create_board do
    %Board{}
    |> Board.changeset(%{
      name: "Board",
      slug: "ph-#{System.unique_integer([:positive])}",
      ap_enabled: true
    })
    |> Repo.insert!()
  end

  defp create_user(opts \\ []) do
    role = Repo.one!(from r in Setup.Role, where: r.name == "user")

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => "ph#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    changes = Keyword.take(opts, [:is_bot, :status]) |> Map.new()

    user =
      if changes == %{}, do: user, else: user |> Ecto.Changeset.change(changes) |> Repo.update!()

    Repo.preload(user, :role)
  end

  defp create_article(user, board) do
    Content.create_article(
      %{
        title: "An article",
        body: "Body",
        slug: "ph-art-#{System.unique_integer([:positive])}",
        user_id: user.id
      },
      [board.id]
    )
  end

  defp create_remote_article(board) do
    actor = create_remote_actor()
    n = System.unique_integer([:positive])

    {:ok, _} =
      Content.create_remote_article(
        %{
          title: "Theirs",
          body: "Mirrored",
          slug: "ph-remote-#{n}",
          ap_id: "https://remote.example/articles/#{n}",
          remote_actor_id: actor.id,
          visibility: "public"
        },
        [board.id]
      )
  end

  defp create_remote_actor do
    n = System.unique_integer([:positive])

    %RemoteActor{}
    |> RemoteActor.changeset(%{
      ap_id: "https://remote.example/users/a#{n}",
      username: "a#{n}",
      domain: "remote.example",
      public_key_pem: "-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----",
      inbox: "https://remote.example/users/a#{n}/inbox",
      actor_type: "Person",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end
end
