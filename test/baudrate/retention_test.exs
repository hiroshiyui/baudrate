defmodule Baudrate.RetentionTest do
  @moduledoc """
  Acceptance gate for Phase 2F. Retention deletes permanently, so each keep
  rule gets a test of its own: what is old enough goes, what somebody touched
  stays, and what a report points at stays whatever its age.
  """

  use Baudrate.DataCase, async: false

  import Ecto.Query

  alias Baudrate.Content
  alias Baudrate.Content.{Article, ArticleImage, Board, Comment}
  alias Baudrate.Federation
  alias Baudrate.Federation.{Announce, RemoteActor, TimelineItem}
  alias Baudrate.Moderation.Report
  alias Baudrate.Repo
  alias Baudrate.Retention
  alias Baudrate.Setup
  alias Baudrate.Setup.{Role, User}

  setup do
    unless Repo.exists?(from(r in Role, where: r.name == "admin")) do
      Setup.seed_roles_and_permissions()
    end

    {:ok, user: create_user(), actor: create_remote_actor()}
  end

  defp create_user do
    role = Repo.one!(from(r in Role, where: r.name == "user"))

    {:ok, user} =
      %User{}
      |> User.registration_changeset(%{
        "username" => "ret_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    user
  end

  defp create_remote_actor do
    uid = System.unique_integer([:positive])

    {:ok, actor} =
      %RemoteActor{}
      |> RemoteActor.changeset(%{
        ap_id: "https://remote.example/users/actor-#{uid}",
        username: "actor_#{uid}",
        domain: "remote.example",
        display_name: "Actor #{uid}",
        public_key_pem: "-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----",
        inbox: "https://remote.example/users/actor-#{uid}/inbox",
        actor_type: "Person",
        fetched_at: now()
      })
      |> Repo.insert()

    actor
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp create_timeline_item(actor, age_days) do
    uid = System.unique_integer([:positive])

    {:ok, item} =
      %TimelineItem{}
      |> TimelineItem.changeset(%{
        remote_actor_id: actor.id,
        activity_type: "Create",
        object_type: "Note",
        ap_id: "https://remote.example/notes/#{uid}",
        body: "Hello",
        body_html: "<p>Hello</p>",
        source_url: "https://remote.example/notes/#{uid}",
        published_at: now()
      })
      |> Repo.insert()

    age(TimelineItem, item.id, :inserted_at, age_days)
    item
  end

  defp create_announce(actor, age_days) do
    uid = System.unique_integer([:positive])

    {:ok, announce} =
      %Announce{}
      |> Announce.changeset(%{
        ap_id: "https://remote.example/activities/announce-#{uid}",
        target_ap_id: "https://remote.example/notes/#{uid}",
        activity_id: "https://remote.example/activities/#{uid}",
        remote_actor_id: actor.id
      })
      |> Repo.insert()

    age(Announce, announce.id, :inserted_at, age_days)
    announce
  end

  # Explicit timestamps rather than sleeping (the suite must stay deterministic
  # across partitions).
  defp age(schema, id, field, days) do
    stamp = DateTime.add(now(), -days * 86_400, :second)
    Repo.update_all(from(x in schema, where: x.id == ^id), set: [{field, stamp}])
  end

  defp create_board do
    {:ok, board} =
      %Board{}
      |> Board.changeset(%{
        name: "Retention #{System.unique_integer([:positive])}",
        slug: "retention-#{System.unique_integer([:positive])}",
        description: "for retention tests"
      })
      |> Repo.insert()

    board
  end

  defp create_article(user, board) do
    # `create_article/3` returns the Ecto.Multi changes map, not the article.
    {:ok, %{article: article}} =
      Content.create_article(
        %{
          "title" => "Article #{System.unique_integer([:positive])}",
          "slug" => "article-#{System.unique_integer([:positive])}",
          "body" => "body",
          "user_id" => user.id
        },
        [board.id]
      )

    article
  end

  defp soft_delete(schema, id, age_days) do
    stamp = DateTime.add(now(), -age_days * 86_400, :second)
    Repo.update_all(from(x in schema, where: x.id == ^id), set: [deleted_at: stamp])
  end

  defp exists?(schema, id), do: Repo.exists?(from(x in schema, where: x.id == ^id))

  # An item is only interactable through an accepted follow of its actor
  # (`Federation.timeline_item_accessible?/2`), so the keep-rule tests need one.
  defp follow(user, actor) do
    {:ok, follow} = Federation.create_user_follow(user, actor)
    {:ok, follow} = Federation.accept_user_follow(follow.ap_id)
    follow
  end

  describe "purge_timeline_items/1" do
    test "removes an untouched item past the window", %{actor: actor} do
      old = create_timeline_item(actor, 91)
      recent = create_timeline_item(actor, 89)

      assert Retention.purge_timeline_items() >= 1

      refute exists?(TimelineItem, old.id)
      assert exists?(TimelineItem, recent.id)
    end

    test "keeps an item somebody liked", %{actor: actor, user: user} do
      follow(user, actor)
      item = create_timeline_item(actor, 200)
      assert {:ok, _like} = Federation.toggle_timeline_item_like(user, item.id)

      Retention.purge_timeline_items()

      assert exists?(TimelineItem, item.id)
    end

    test "keeps an item somebody boosted", %{actor: actor, user: user} do
      follow(user, actor)
      item = create_timeline_item(actor, 200)
      assert {:ok, _boost} = Federation.toggle_timeline_item_boost(user, item.id)

      Retention.purge_timeline_items()

      assert exists?(TimelineItem, item.id)
    end

    test "keeps an item somebody replied to", %{actor: actor, user: user} do
      follow(user, actor)
      item = create_timeline_item(actor, 200)
      assert {:ok, _reply} = Federation.create_timeline_item_reply(item, user, "a reply")

      Retention.purge_timeline_items()

      assert exists?(TimelineItem, item.id)
    end

    test "keeps an item a report points at, however old", %{actor: actor, user: user} do
      item = create_timeline_item(actor, 400)

      Repo.insert!(%Report{
        reporter_id: user.id,
        timeline_item_id: item.id,
        reason: "spam",
        status: "resolved",
        resolved_at: DateTime.add(now(), -365 * 86_400, :second)
      })

      Retention.purge_timeline_items()

      assert exists?(TimelineItem, item.id),
             "a reported item must survive: reports.timeline_item_id nilifies, " <>
               "so deleting it would empty the moderation record instead of refusing"
    end

    test "dry_run counts without deleting", %{actor: actor} do
      item = create_timeline_item(actor, 91)

      assert Retention.purge_timeline_items(dry_run: true) >= 1
      assert exists?(TimelineItem, item.id)
    end

    test "works in batches smaller than the backlog", %{actor: actor} do
      items = for _ <- 1..5, do: create_timeline_item(actor, 91)

      assert Retention.purge_timeline_items(batch: 2) >= 5

      for item <- items, do: refute(exists?(TimelineItem, item.id))
    end
  end

  describe "purge_announces/1" do
    test "removes records past the window and keeps newer ones", %{actor: actor} do
      old = create_announce(actor, 181)
      recent = create_announce(actor, 179)

      assert Retention.purge_announces() >= 1

      refute exists?(Announce, old.id)
      assert exists?(Announce, recent.id)
    end
  end

  describe "purge_soft_deleted/1" do
    test "hard-deletes an article soft-deleted past the evidence window", %{user: user} do
      board = create_board()
      article = create_article(user, board)
      soft_delete(Article, article.id, 91)

      {articles, _comments, _files} = Retention.purge_soft_deleted()

      assert articles >= 1
      refute exists?(Article, article.id)
    end

    test "keeps one still inside the window", %{user: user} do
      board = create_board()
      article = create_article(user, board)
      soft_delete(Article, article.id, 89)

      Retention.purge_soft_deleted()

      assert exists?(Article, article.id)
    end

    test "keeps an article a report points at", %{user: user} do
      board = create_board()
      article = create_article(user, board)
      soft_delete(Article, article.id, 400)

      Repo.insert!(%Report{
        reporter_id: user.id,
        article_id: article.id,
        reason: "spam",
        status: "resolved",
        resolved_at: DateTime.add(now(), -365 * 86_400, :second)
      })

      Retention.purge_soft_deleted()

      assert exists?(Article, article.id)
    end

    test "hard-deletes a soft-deleted comment", %{user: user} do
      board = create_board()
      article = create_article(user, board)

      {:ok, comment} =
        Content.create_comment(%{
          "body" => "hi",
          "article_id" => article.id,
          "user_id" => user.id
        })

      soft_delete(Comment, comment.id, 91)

      {_articles, comments, _files} = Retention.purge_soft_deleted()

      assert comments >= 1
      refute exists?(Comment, comment.id)
    end

    test "removes the image files a purged article leaves behind", %{user: user} do
      board = create_board()
      article = create_article(user, board)

      path = Path.join(System.tmp_dir!(), "retention_#{System.unique_integer([:positive])}.webp")
      File.write!(path, "not really an image")

      Repo.insert!(%ArticleImage{
        article_id: article.id,
        filename: Path.basename(path),
        storage_path: path,
        width: 1,
        height: 1,
        user_id: user.id
      })

      soft_delete(Article, article.id, 91)

      {_articles, _comments, files} = Retention.purge_soft_deleted()

      assert files >= 1
      refute File.exists?(path), "the row cascades, so nothing would ever find the file again"
    end

    test "dry_run counts without deleting", %{user: user} do
      board = create_board()
      article = create_article(user, board)
      soft_delete(Article, article.id, 91)

      assert {articles, _, _} = Retention.purge_soft_deleted(dry_run: true)
      assert articles >= 1
      assert exists?(Article, article.id)
    end
  end

  describe "run/1" do
    test "reports what every pass removed", %{actor: actor} do
      create_timeline_item(actor, 91)
      create_announce(actor, 181)

      counts = Retention.run()

      assert counts.timeline_items >= 1
      assert counts.announces >= 1
      assert is_integer(counts.articles)
      assert is_integer(counts.comments)
    end

    test "running again removes nothing", %{actor: actor} do
      create_timeline_item(actor, 91)
      Retention.run()

      assert %{timeline_items: 0, announces: 0, articles: 0, comments: 0} = Retention.run()
    end
  end
end
