defmodule Baudrate.Content.SitemapTest do
  @moduledoc """
  The inventory queries behind `sitemap.xml` (ADR 0057).

  `BaudrateWeb.CrawlerSurfaceTest` is the acceptance gate for what reaches a
  crawler; this covers the queries themselves, including the paging boundary
  the controller turns into a 404.
  """
  use Baudrate.DataCase, async: true

  alias Baudrate.Content
  alias Baudrate.Content.{Article, Board, BoardArticle, Sitemap}
  alias Baudrate.Federation.RemoteActor
  alias Baudrate.Repo

  setup do
    Baudrate.Setup.seed_roles_and_permissions()
    user = create_user()
    public_board = insert_board("public-board", "guest")
    private_board = insert_board("private-board", "user")

    %{user: user, public_board: public_board, private_board: private_board}
  end

  describe "public_boards/0" do
    test "lists guest-viewable boards only", %{public_board: public, private_board: private} do
      slugs = Sitemap.public_boards() |> Enum.map(&elem(&1, 0))

      assert public.slug in slugs
      refute private.slug in slugs
    end

    test "a board with nothing in it has no lastmod", %{public_board: board} do
      assert {_slug, nil} = Enum.find(Sitemap.public_boards(), &(elem(&1, 0) == board.slug))
    end

    test "lastmod follows the board's last activity", %{user: user, public_board: board} do
      {:ok, _} = insert_article(user, board, "dated")

      assert {_slug, %DateTime{}} =
               Enum.find(Sitemap.public_boards(), &(elem(&1, 0) == board.slug))
    end
  end

  describe "the article predicate" do
    test "includes a public local article in a public board", %{user: user, public_board: board} do
      {:ok, _} = insert_article(user, board, "included")

      assert "included" in slugs()
      assert Sitemap.count_public_articles() == 1
    end

    test "excludes an article that lives only in a private board", %{
      user: user,
      private_board: board
    } do
      {:ok, _} = insert_article(user, board, "hidden")

      refute "hidden" in slugs()
    end

    test "includes a cross-posted article as soon as one of its boards is public", %{
      user: user,
      public_board: public,
      private_board: private
    } do
      {:ok, _} =
        Content.create_article(article_attrs(user, "crossposted"), [private.id, public.id])

      assert "crossposted" in slugs()
    end

    test "excludes a soft-deleted article", %{user: user, public_board: board} do
      {:ok, %{article: article}} = insert_article(user, board, "deleted")
      Content.soft_delete_article(article, deleted_by: article.user_id)

      refute "deleted" in slugs()
    end

    test "excludes an unlisted article", %{user: user, public_board: board} do
      {:ok, _} =
        Content.create_article(
          article_attrs(user, "unlisted") |> Map.put(:visibility, "unlisted"),
          [board.id]
        )

      refute "unlisted" in slugs()
    end

    test "excludes a remote article", %{public_board: board} do
      insert_remote_article(board, "remote")

      refute "remote" in slugs()
    end
  end

  describe "public_article_slugs/2" do
    test "pages by id, without overlap or gaps", %{user: user, public_board: board} do
      for n <- 1..5, do: {:ok, _} = insert_article(user, board, "paged-#{n}")

      first = Sitemap.public_article_slugs(0, 2) |> Enum.map(&elem(&1, 0))
      second = Sitemap.public_article_slugs(2, 2) |> Enum.map(&elem(&1, 0))
      third = Sitemap.public_article_slugs(4, 2) |> Enum.map(&elem(&1, 0))

      assert length(first) == 2
      assert length(second) == 2
      assert length(third) == 1
      assert Enum.uniq(first ++ second ++ third) |> length() == 5
    end

    test "past the end is empty, which is what the controller turns into a 404", %{
      user: user,
      public_board: board
    } do
      {:ok, _} = insert_article(user, board, "only-one")

      assert Sitemap.public_article_slugs(5_000, 5_000) == []
    end

    test "lastmod comes back as a DateTime, not a naive one", %{
      user: user,
      public_board: board
    } do
      {:ok, _} = insert_article(user, board, "typed")

      assert [{"typed", %DateTime{}}] = Sitemap.public_article_slugs(0, 10)
    end
  end

  describe "public_tags/0" do
    test "lists a tag carried by a listed article", %{user: user, public_board: board} do
      {:ok, _} =
        Content.create_article(
          %{article_attrs(user, "tagged") | body: "About #elixir today."},
          [board.id]
        )

      assert "elixir" in Sitemap.public_tags()
    end

    test "a tag used only from a private board is not an existence signal", %{
      user: user,
      private_board: board
    } do
      {:ok, _} =
        Content.create_article(
          %{article_attrs(user, "secret-tagged") | body: "About #cabal today."},
          [board.id]
        )

      refute "cabal" in Sitemap.public_tags()
    end
  end

  describe "newest_article_date/0" do
    test "is nil on an empty instance" do
      assert Sitemap.newest_article_date() == nil
    end

    test "is a DateTime once something is published", %{user: user, public_board: board} do
      {:ok, _} = insert_article(user, board, "dated-inventory")

      assert %DateTime{} = Sitemap.newest_article_date()
    end
  end

  defp create_user do
    role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == "user"))

    %Baudrate.Setup.User{}
    |> Baudrate.Setup.User.registration_changeset(%{
      "username" => "user_#{System.unique_integer([:positive])}",
      "password" => "Password123!x",
      "password_confirmation" => "Password123!x",
      "role_id" => role.id
    })
    |> Repo.insert!()
  end

  defp slugs, do: Sitemap.public_article_slugs(0, 1_000) |> Enum.map(&elem(&1, 0))

  defp article_attrs(user, slug) do
    %{title: "Article #{slug}", body: "Body for #{slug}.", slug: slug, user_id: user.id}
  end

  defp insert_article(user, board, slug) do
    Content.create_article(article_attrs(user, slug), [board.id])
  end

  defp insert_board(slug, min_role_to_view) do
    %Board{}
    |> Board.changeset(%{
      name: "Board #{slug}",
      slug: slug,
      description: "Test board for #{slug}",
      min_role_to_view: min_role_to_view,
      min_role_to_post: "user"
    })
    |> Repo.insert!()
  end

  defp insert_remote_article(board, slug) do
    actor =
      %RemoteActor{}
      |> RemoteActor.changeset(%{
        ap_id: "https://remote.example/actor/#{slug}",
        username: "remote_#{slug}",
        domain: "remote.example",
        public_key_pem: "-----BEGIN PUBLIC KEY-----\nMIIBIjANBg==\n-----END PUBLIC KEY-----",
        inbox: "https://remote.example/inbox",
        shared_inbox: "https://remote.example/inbox",
        actor_type: "Person",
        fetched_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    article =
      %Article{}
      |> Article.remote_changeset(%{
        title: "Remote #{slug}",
        body: "Remote body",
        slug: slug,
        ap_id: "https://remote.example/articles/#{slug}",
        remote_actor_id: actor.id
      })
      |> Repo.insert!()

    Repo.insert!(%BoardArticle{
      board_id: board.id,
      article_id: article.id,
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })

    article
  end
end
