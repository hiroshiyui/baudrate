defmodule Baudrate.Federation.ObjectBuilderTest do
  @moduledoc """
  The `Article` object is what every remote instance stores as our content, and
  the fields it keys on — `id`, `attributedTo`, `to`/`cc`, `updated` — are not
  re-derivable once a peer has cached them. These pin the shape.
  """
  use Baudrate.DataCase, async: false

  import Ecto.Query

  alias Baudrate.Content
  alias Baudrate.Content.Board
  alias Baudrate.Federation
  alias Baudrate.Federation.ObjectBuilder
  alias Baudrate.Repo
  alias Baudrate.Setup

  @as_public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    unless Repo.exists?(from(r in Setup.Role, where: r.name == "admin")) do
      Setup.seed_roles_and_permissions()
    end

    user = create_user("user")
    board = create_board()
    {:ok, user: user, board: board}
  end

  defp create_user(role_name) do
    role = Repo.one!(from(r in Setup.Role, where: r.name == ^role_name))

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => "objbuild_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  defp create_board do
    %Board{}
    |> Board.changeset(%{
      name: "Obj Board",
      slug: "obj-board-#{System.unique_integer([:positive])}",
      ap_enabled: true,
      min_role_to_view: "guest"
    })
    |> Repo.insert!()
  end

  defp create_article(user, board, attrs \\ %{}) do
    {:ok, %{article: article}} =
      Content.create_article(
        Map.merge(
          %{
            title: "An Article",
            body: "Some **body** text",
            slug: "obj-article-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          attrs
        ),
        [board.id]
      )

    article
  end

  describe "article_object/1" do
    test "builds an addressed, attributed Article", %{user: user, board: board} do
      article = create_article(user, board)
      object = ObjectBuilder.article_object(article)

      assert object["type"] == "Article"
      assert object["name"] == "An Article"
      assert object["attributedTo"] == Federation.actor_uri(:user, user.username)

      # Public addressing plus the board as audience is what makes a Lemmy-style
      # Group deliver it onward.
      assert object["to"] == [@as_public]
      assert object["cc"] == [Federation.actor_uri(:board, board.slug)]
      assert object["audience"] == [Federation.actor_uri(:board, board.slug)]

      assert object["url"] == "#{Federation.base_url()}/articles/#{article.slug}"
      assert object["replies"] == "#{object["id"]}/replies"
    end

    test "uses the stored ap_id as the object id", %{user: user, board: board} do
      article = create_article(user, board)

      # Stamped post-insert, since the URI embeds the DB-assigned id. A peer
      # that already cached this id must keep resolving to the same object.
      assert article.ap_id
      assert ObjectBuilder.article_object(article)["id"] == article.ap_id
    end

    test "falls back to the derived URI when ap_id was never stamped", %{
      user: user,
      board: board
    } do
      article = create_article(user, board)
      {:ok, article} = article |> Ecto.Changeset.change(%{ap_id: nil}) |> Repo.update()

      object = ObjectBuilder.article_object(article)
      assert object["id"] == Federation.actor_uri(:article, article.slug)
      assert object["replies"] == "#{object["id"]}/replies"
    end

    test "carries both rendered HTML and the Markdown source", %{user: user, board: board} do
      article = create_article(user, board, %{body: "Some **body** text"})
      object = ObjectBuilder.article_object(article)

      assert object["mediaType"] == "text/html"
      assert object["content"] =~ "<strong>body</strong>"
      assert object["source"]["mediaType"] == "text/markdown"
      assert object["source"]["content"] == "Some **body** text"
    end

    test "summarises the body as plain text, stripped of Markdown", %{user: user, board: board} do
      body = """
      # A heading

      Text with **bold**, `code`, and a [link](https://example.com).
      """

      object = create_article(user, board, %{body: body}) |> ObjectBuilder.article_object()

      assert object["summary"] =~ "A heading"
      assert object["summary"] =~ "link"
      refute object["summary"] =~ "**"
      refute object["summary"] =~ "https://example.com"
      refute object["summary"] =~ "#"
    end

    test "truncates a long summary at a word boundary", %{user: user, board: board} do
      body = String.duplicate("word ", 500)
      object = create_article(user, board, %{body: body}) |> ObjectBuilder.article_object()

      assert String.length(object["summary"]) <= 501
      assert String.ends_with?(object["summary"], "…")
    end

    test "omits `updated` until the article is genuinely edited", %{user: user, board: board} do
      article = create_article(user, board)

      # Mastodon renders an "edited" badge whenever updated != published, so
      # post-insert housekeeping (ap_id stamping) must not trip it.
      refute Map.has_key?(ObjectBuilder.article_object(article), "updated")

      later = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
      {:ok, edited} = article |> Ecto.Changeset.change(%{updated_at: later}) |> Repo.update()

      assert ObjectBuilder.article_object(edited)["updated"] == DateTime.to_iso8601(later)
    end

    test "emits Hashtag tags only when the body has hashtags", %{user: user, board: board} do
      plain = create_article(user, board, %{body: "no tags here"})
      refute Map.has_key?(ObjectBuilder.article_object(plain), "tag")

      tagged = create_article(user, board, %{body: "about #elixir and #beam"})
      tags = ObjectBuilder.article_object(tagged)["tag"]

      assert Enum.all?(tags, &(&1["type"] == "Hashtag"))
      names = Enum.map(tags, & &1["name"])
      assert "#elixir" in names
      assert "#beam" in names

      elixir_tag = Enum.find(tags, &(&1["name"] == "#elixir"))
      assert elixir_tag["href"] == "#{Federation.base_url()}/tags/elixir"
    end

    test "embeds a poll as a Question, keyed by mode", %{user: user, board: board} do
      for {mode, key} <- [{"single", "oneOf"}, {"multiple", "anyOf"}] do
        {:ok, %{article: article}} =
          Content.create_article(
            %{
              title: "Poll Article",
              body: "vote",
              slug: "poll-#{mode}-#{System.unique_integer([:positive])}",
              user_id: user.id
            },
            [board.id],
            poll: %{
              mode: mode,
              options: [%{text: "Yes", position: 0}, %{text: "No", position: 1}]
            }
          )

        object = ObjectBuilder.article_object(article)
        question = Enum.find(object["attachment"], &(&1["type"] == "Question"))

        assert question, "expected a Question attachment for mode #{mode}"
        assert question["votersCount"] == 0
        assert Enum.map(question[key], & &1["name"]) == ["Yes", "No"]

        # Vote counts ride in a Collection per option, per AS2 Question.
        assert Enum.all?(question[key], &(&1["replies"]["type"] == "Collection"))
      end
    end

    test "omits `attachment` entirely when there is nothing to attach", %{
      user: user,
      board: board
    } do
      article = create_article(user, board)
      refute Map.has_key?(ObjectBuilder.article_object(article), "attachment")
    end
  end
end
