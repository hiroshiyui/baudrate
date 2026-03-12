defmodule Baudrate.Content.InteractionsTest do
  use Baudrate.DataCase

  alias Baudrate.Content
  alias Baudrate.Content.Interactions
  alias Baudrate.Setup

  setup do
    unless Repo.exists?(from(r in Setup.Role, where: r.name == "admin")) do
      Setup.seed_roles_and_permissions()
    end

    :ok
  end

  defp create_user(role_name) do
    role = Repo.one!(from(r in Setup.Role, where: r.name == ^role_name))

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => "ix_#{role_name}_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  defp create_board(attrs \\ %{}) do
    default = %{
      name: "Test Board",
      slug: "ix-#{System.unique_integer([:positive])}",
      min_role_to_view: "guest"
    }

    {:ok, board} = Content.create_board(Map.merge(default, attrs))
    board
  end

  defp create_article(user, board) do
    slug = "ix-art-#{System.unique_integer([:positive])}"

    {:ok, %{article: article}} =
      Content.create_article(
        %{title: "Test Article", body: "Body", slug: slug, user_id: user.id},
        [board.id]
      )

    article
  end

  describe "accessible_roles/1" do
    test "admin can access all roles" do
      assert Interactions.accessible_roles("admin") == ~w(guest user moderator admin)
    end

    test "moderator can access guest, user, and moderator" do
      assert Interactions.accessible_roles("moderator") == ~w(guest user moderator)
    end

    test "user can access guest and user" do
      assert Interactions.accessible_roles("user") == ~w(guest user)
    end

    test "guest can access only guest" do
      assert Interactions.accessible_roles("guest") == ~w(guest)
    end

    test "unknown role defaults to guest-level access" do
      assert Interactions.accessible_roles("unknown") == ~w(guest)
    end

    test "nil role defaults to guest-level access" do
      assert Interactions.accessible_roles(nil) == ~w(guest)
    end
  end

  describe "article_visible_to_user?/2" do
    test "article in guest-visible board is visible to any user" do
      user = create_user("user")
      board = create_board(%{min_role_to_view: "guest"})
      article = create_article(user, board)

      guest = create_user("guest")
      assert Interactions.article_visible_to_user?(article.id, guest.id)
    end

    test "article in guest-visible board is visible to user role" do
      author = create_user("user")
      board = create_board(%{min_role_to_view: "guest"})
      article = create_article(author, board)

      viewer = create_user("user")
      assert Interactions.article_visible_to_user?(article.id, viewer.id)
    end

    test "article in user-visible board is not visible to guest" do
      author = create_user("user")
      board = create_board(%{min_role_to_view: "user"})
      article = create_article(author, board)

      guest = create_user("guest")
      refute Interactions.article_visible_to_user?(article.id, guest.id)
    end

    test "article in user-visible board is visible to user" do
      author = create_user("user")
      board = create_board(%{min_role_to_view: "user"})
      article = create_article(author, board)

      viewer = create_user("user")
      assert Interactions.article_visible_to_user?(article.id, viewer.id)
    end

    test "article in moderator-visible board is not visible to user" do
      author = create_user("moderator")
      board = create_board(%{min_role_to_view: "moderator"})
      article = create_article(author, board)

      viewer = create_user("user")
      refute Interactions.article_visible_to_user?(article.id, viewer.id)
    end

    test "article in moderator-visible board is visible to moderator" do
      author = create_user("moderator")
      board = create_board(%{min_role_to_view: "moderator"})
      article = create_article(author, board)

      viewer = create_user("moderator")
      assert Interactions.article_visible_to_user?(article.id, viewer.id)
    end

    test "article in admin-visible board is visible to admin" do
      author = create_user("admin")
      board = create_board(%{min_role_to_view: "admin"})
      article = create_article(author, board)

      viewer = create_user("admin")
      assert Interactions.article_visible_to_user?(article.id, viewer.id)
    end

    test "article in admin-visible board is not visible to moderator" do
      author = create_user("admin")
      board = create_board(%{min_role_to_view: "admin"})
      article = create_article(author, board)

      viewer = create_user("moderator")
      refute Interactions.article_visible_to_user?(article.id, viewer.id)
    end

    test "board-less article is visible to any user" do
      user = create_user("user")

      # Create an article without board associations
      {:ok, article} =
        %Content.Article{}
        |> Content.Article.changeset(%{
          title: "Boardless",
          body: "No board",
          slug: "ix-boardless-#{System.unique_integer([:positive])}",
          user_id: user.id
        })
        |> Repo.insert()

      guest = create_user("guest")
      assert Interactions.article_visible_to_user?(article.id, guest.id)
    end

    test "returns true for non-existent user viewing guest-visible board article" do
      author = create_user("user")
      board = create_board(%{min_role_to_view: "guest"})
      article = create_article(author, board)

      # Non-existent user_id treated as guest
      assert Interactions.article_visible_to_user?(article.id, -1)
    end

    test "non-existent user cannot see user-restricted board article" do
      author = create_user("user")
      board = create_board(%{min_role_to_view: "user"})
      article = create_article(author, board)

      refute Interactions.article_visible_to_user?(article.id, -1)
    end
  end

  describe "has_unique_constraint_error?/1" do
    test "returns true for changeset with unique constraint error" do
      changeset = %Ecto.Changeset{
        errors: [
          {:article_id,
           {"has already been taken", [constraint: :unique, constraint_name: "some_index"]}}
        ],
        valid?: false
      }

      assert Interactions.has_unique_constraint_error?(changeset)
    end

    test "returns false for changeset with other errors" do
      changeset = %Ecto.Changeset{
        errors: [
          {:article_id, {"can't be blank", [validation: :required]}}
        ],
        valid?: false
      }

      refute Interactions.has_unique_constraint_error?(changeset)
    end

    test "returns false for changeset with no errors" do
      changeset = %Ecto.Changeset{errors: [], valid?: true}

      refute Interactions.has_unique_constraint_error?(changeset)
    end

    test "returns true when unique constraint error is among multiple errors" do
      changeset = %Ecto.Changeset{
        errors: [
          {:user_id, {"can't be blank", [validation: :required]}},
          {:article_id,
           {"has already been taken", [constraint: :unique, constraint_name: "some_index"]}}
        ],
        valid?: false
      }

      assert Interactions.has_unique_constraint_error?(changeset)
    end
  end

  describe "stamp_ap_id/2" do
    test "stamps ap_id on a local record with nil ap_id" do
      user = create_user("user")
      board = create_board()
      article = create_article(user, board)

      {:ok, like} =
        %Content.ArticleLike{}
        |> Content.ArticleLike.changeset(%{article_id: article.id, user_id: user.id})
        |> Repo.insert()

      assert like.ap_id == nil

      stamped = Interactions.stamp_ap_id(like, "like")

      expected_ap_id =
        Baudrate.Federation.actor_uri(:user, user.username) <> "#like-#{like.id}"

      assert stamped.ap_id == expected_ap_id
    end

    test "does not stamp ap_id on record that already has one" do
      user = create_user("user")
      board = create_board()
      article = create_article(user, board)

      existing_ap_id = "https://example.com/likes/existing"

      {:ok, like} =
        %Content.ArticleLike{}
        |> change(%{
          article_id: article.id,
          user_id: user.id,
          ap_id: existing_ap_id
        })
        |> Repo.insert()

      result = Interactions.stamp_ap_id(like, "like")

      assert result.ap_id == existing_ap_id
    end

    test "does not stamp ap_id when user_id is not an integer" do
      record = %{ap_id: nil, user_id: nil, id: 1}
      result = Interactions.stamp_ap_id(record, "like")

      assert result == record
    end

    test "returns record unchanged when user does not exist" do
      # Simulate a record whose user has been deleted —
      # pass a plain map with a non-existent user_id
      record = %{ap_id: nil, user_id: -999, id: 42}
      result = Interactions.stamp_ap_id(record, "like")

      assert result == record
    end
  end

  describe "schedule_federation_task/1" do
    test "executes the given function synchronously in test" do
      test_pid = self()

      Interactions.schedule_federation_task(fn ->
        send(test_pid, :task_executed)
      end)

      assert_receive :task_executed
    end
  end
end
