defmodule Baudrate.Content.ArticleTagTest do
  use Baudrate.DataCase

  alias Baudrate.Content.{ArticleTag, Board}
  alias Baudrate.Setup

  setup do
    Setup.seed_roles_and_permissions()
    :ok
  end

  defp create_user do
    role = Repo.one!(from(r in Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => "tagger_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  defp create_article(user) do
    board =
      %Board{}
      |> Board.changeset(%{
        name: "Tag Board",
        slug: "tag-board-#{System.unique_integer([:positive])}"
      })
      |> Repo.insert!()

    {:ok, %{article: article}} =
      Baudrate.Content.create_article(
        %{
          title: "Tagged Article",
          body: "Body",
          slug: "tag-art-#{System.unique_integer([:positive])}",
          user_id: user.id
        },
        [board.id]
      )

    article
  end

  describe "changeset/2" do
    test "valid tag with article_id" do
      user = create_user()
      article = create_article(user)

      changeset =
        ArticleTag.changeset(%ArticleTag{}, %{article_id: article.id, tag: "elixir"})

      assert changeset.valid?
    end

    test "rejects empty tag" do
      changeset = ArticleTag.changeset(%ArticleTag{}, %{article_id: 1, tag: ""})
      assert %{tag: [_ | _]} = errors_on(changeset)
    end

    test "rejects missing tag" do
      changeset = ArticleTag.changeset(%ArticleTag{}, %{article_id: 1})
      assert %{tag: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects tag longer than 64 characters" do
      long_tag = String.duplicate("a", 65)
      changeset = ArticleTag.changeset(%ArticleTag{}, %{article_id: 1, tag: long_tag})
      assert %{tag: [_ | _]} = errors_on(changeset)
    end

    test "rejects tag with invalid characters" do
      changeset = ArticleTag.changeset(%ArticleTag{}, %{article_id: 1, tag: "hello world"})
      assert %{tag: [_ | _]} = errors_on(changeset)
    end

    test "rejects tag starting with a number" do
      changeset = ArticleTag.changeset(%ArticleTag{}, %{article_id: 1, tag: "123abc"})
      assert %{tag: [_ | _]} = errors_on(changeset)
    end

    test "rejects tag starting with underscore" do
      changeset = ArticleTag.changeset(%ArticleTag{}, %{article_id: 1, tag: "_hello"})
      assert %{tag: [_ | _]} = errors_on(changeset)
    end

    test "accepts CJK tag" do
      changeset = ArticleTag.changeset(%ArticleTag{}, %{article_id: 1, tag: "elixir"})
      assert changeset.valid?

      changeset_cjk = ArticleTag.changeset(%ArticleTag{}, %{article_id: 1, tag: "台灣"})
      assert changeset_cjk.valid?
    end

    test "duplicate article_id + tag raises unique constraint error" do
      user = create_user()
      article = create_article(user)

      {:ok, _} =
        %ArticleTag{}
        |> ArticleTag.changeset(%{article_id: article.id, tag: "elixir"})
        |> Repo.insert()

      {:error, changeset} =
        %ArticleTag{}
        |> ArticleTag.changeset(%{article_id: article.id, tag: "elixir"})
        |> Repo.insert()

      assert %{article_id: [_ | _]} = errors_on(changeset)
    end
  end
end
