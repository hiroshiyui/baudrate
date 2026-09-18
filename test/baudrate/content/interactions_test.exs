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

  # `accessible_roles/1` used to live here: a third hand-written copy of the
  # role hierarchy, after `@role_levels` and `roles_at_or_below/1`. It is gone,
  # and `article_visible_to_user?/2` reads `Setup.roles_at_or_below/1`, which
  # `test/baudrate/setup_test.exs` covers.

  describe "article_visible_to_user?/2 refuses remote rows" do
    # A remote article ingested as followers-only/direct keeps that visibility
    # (ADR 0030 loses visibility rather than data), and it is refused to
    # everyone including admins: re-publishing someone else's followers-only
    # post is not a trust question. This check lived only in the web layer,
    # so the article page refused such a row while like, boost, bookmark and
    # forward all accepted it.
    test "a followers-only remote article is refused, even to an admin" do
      admin = create_user("admin")
      board = create_board(%{min_role_to_view: "guest"})
      article = remote_article(board, "followers_only")

      refute Interactions.article_visible_to_user?(article.id, admin.id)
    end

    test "a direct remote article is refused" do
      user = create_user("user")
      board = create_board(%{min_role_to_view: "guest"})
      article = remote_article(board, "direct")

      refute Interactions.article_visible_to_user?(article.id, user.id)
    end

    test "a public remote article in a readable board is allowed" do
      user = create_user("user")
      board = create_board(%{min_role_to_view: "guest"})
      article = remote_article(board, "public")

      assert Interactions.article_visible_to_user?(article.id, user.id)
    end

    # The board check still applies on top of the remote one.
    test "a public remote article in an unreadable board is refused" do
      user = create_user("user")
      board = create_board(%{min_role_to_view: "admin"})
      article = remote_article(board, "public")

      refute Interactions.article_visible_to_user?(article.id, user.id)
    end

    # An id that resolves to nothing used to count as visible: the board count
    # came back 0, which is also how a legitimate quick post looks.
    test "an article id that does not exist is refused" do
      user = create_user("user")
      refute Interactions.article_visible_to_user?(-1, user.id)
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

  defp remote_article(board, visibility) do
    actor =
      Repo.insert!(%Baudrate.Federation.RemoteActor{
        ap_id: "https://remote.example/users/a#{System.unique_integer([:positive])}",
        username: "a#{System.unique_integer([:positive])}",
        domain: "remote.example",
        inbox: "https://remote.example/inbox",
        actor_type: "Person",
        public_key_pem: "-----BEGIN PUBLIC KEY-----\nstub\n-----END PUBLIC KEY-----",
        fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    author = create_user("user")
    article = create_article(author, board)

    article
    |> Ecto.Changeset.change(%{
      remote_actor_id: actor.id,
      user_id: nil,
      visibility: visibility
    })
    |> Repo.update!()
  end
end
