defmodule Baudrate.Content.ArticleTest do
  use Baudrate.DataCase

  alias Baudrate.Content
  alias Baudrate.Content.Article
  alias Baudrate.Setup

  setup do
    Setup.seed_roles_and_permissions()
    :ok
  end

  describe "ap_id stamping" do
    test "local article gets ap_id stamped on creation" do
      role = Repo.one!(from(r in Setup.Role, where: r.name == "user"))

      {:ok, user} =
        %Setup.User{}
        |> Setup.User.registration_changeset(%{
          "username" => "writer_#{System.unique_integer([:positive])}",
          "password" => "Password123!x",
          "password_confirmation" => "Password123!x",
          "role_id" => role.id
        })
        |> Repo.insert()

      board =
        %Content.Board{}
        |> Content.Board.changeset(%{
          name: "Test",
          slug: "board-#{System.unique_integer([:positive])}"
        })
        |> Repo.insert!()

      slug = "art-#{System.unique_integer([:positive])}"

      {:ok, %{article: article}} =
        Content.create_article(
          %{title: "Test", body: "Body", slug: slug, user_id: user.id},
          [board.id]
        )

      expected = Baudrate.Federation.actor_uri(:article, slug)
      assert article.ap_id == expected

      # Verify persisted in DB
      reloaded = Repo.get!(Article, article.id)
      assert reloaded.ap_id == expected
    end

    test "local article with poll gets both ap_ids stamped" do
      role = Repo.one!(from(r in Setup.Role, where: r.name == "user"))

      {:ok, user} =
        %Setup.User{}
        |> Setup.User.registration_changeset(%{
          "username" => "pollwriter_#{System.unique_integer([:positive])}",
          "password" => "Password123!x",
          "password_confirmation" => "Password123!x",
          "role_id" => role.id
        })
        |> Repo.insert()

      board =
        %Content.Board{}
        |> Content.Board.changeset(%{
          name: "Test",
          slug: "board-#{System.unique_integer([:positive])}"
        })
        |> Repo.insert!()

      slug = "poll-art-#{System.unique_integer([:positive])}"
      future = DateTime.utc_now() |> DateTime.add(86_400) |> DateTime.truncate(:second)

      {:ok, %{article: article, poll: poll}} =
        Content.create_article(
          %{title: "Poll Article", body: "Has a poll", slug: slug, user_id: user.id},
          [board.id],
          poll: %{
            mode: "single",
            closes_at: future,
            options: [
              %{text: "Option A", position: 0},
              %{text: "Option B", position: 1}
            ]
          }
        )

      assert article.ap_id == Baudrate.Federation.actor_uri(:article, slug)
      assert poll.ap_id == article.ap_id <> "#poll"
    end
  end

  describe "body length validation" do
    test "changeset rejects body exceeding 65536 bytes" do
      attrs = %{
        title: "Test",
        body: String.duplicate("x", 65_537),
        slug: "test-slug"
      }

      changeset = Article.changeset(%Article{}, attrs)
      assert %{body: ["should be at most 65536 character(s)"]} = errors_on(changeset)
    end

    test "changeset accepts body at exactly 65536 bytes" do
      attrs = %{
        title: "Test",
        body: String.duplicate("x", 65_536),
        slug: "test-slug"
      }

      changeset = Article.changeset(%Article{}, attrs)
      refute Map.has_key?(errors_on(changeset), :body)
    end

    test "update_changeset rejects oversized body" do
      changeset =
        Article.update_changeset(%Article{}, %{title: "T", body: String.duplicate("x", 65_537)})

      assert %{body: ["should be at most 65536 character(s)"]} = errors_on(changeset)
    end

    test "remote_changeset rejects oversized body" do
      attrs = %{
        title: "T",
        body: String.duplicate("x", 65_537),
        slug: "test",
        ap_id: "https://example.com/1",
        remote_actor_id: 1
      }

      changeset = Article.remote_changeset(%Article{}, attrs)
      assert %{body: ["should be at most 65536 character(s)"]} = errors_on(changeset)
    end

    test "update_remote_changeset rejects oversized body" do
      changeset =
        Article.update_remote_changeset(%Article{}, %{
          title: "T",
          body: String.duplicate("x", 65_537)
        })

      assert %{body: ["should be at most 65536 character(s)"]} = errors_on(changeset)
    end
  end
end
