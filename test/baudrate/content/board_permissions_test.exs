defmodule Baudrate.Content.BoardPermissionsTest do
  use Baudrate.DataCase

  alias Baudrate.Content
  alias Baudrate.Repo
  alias Baudrate.Setup

  import Ecto.Query

  setup do
    unless Repo.exists?(from(r in Setup.Role, where: r.name == "admin")) do
      Setup.seed_roles_and_permissions()
    end

    admin_role = Repo.one!(from(r in Setup.Role, where: r.name == "admin"))
    mod_role = Repo.one!(from(r in Setup.Role, where: r.name == "moderator"))
    user_role = Repo.one!(from(r in Setup.Role, where: r.name == "user"))
    guest_role = Repo.one!(from(r in Setup.Role, where: r.name == "guest"))

    make_user = fn role ->
      {:ok, user} =
        %Setup.User{}
        |> Setup.User.registration_changeset(%{
          "username" => "perm_#{role.name}_#{System.unique_integer([:positive])}",
          "password" => "Password123!x",
          "password_confirmation" => "Password123!x",
          "role_id" => role.id
        })
        |> Repo.insert()

      Repo.preload(user, :role)
    end

    admin = make_user.(admin_role)
    moderator = make_user.(mod_role)
    user = make_user.(user_role)
    guest = make_user.(guest_role)

    # Activate users
    for u <- [admin, moderator, user] do
      Ecto.Changeset.change(u, status: "active") |> Repo.update!()
    end

    admin = Repo.preload(Repo.get!(Setup.User, admin.id), :role)
    moderator = Repo.preload(Repo.get!(Setup.User, moderator.id), :role)
    user = Repo.preload(Repo.get!(Setup.User, user.id), :role)

    {:ok, admin: admin, moderator: moderator, user: user, guest: guest}
  end

  describe "role_level/1" do
    test "returns correct levels" do
      assert Setup.role_level("guest") == 0
      assert Setup.role_level("user") == 1
      assert Setup.role_level("moderator") == 2
      assert Setup.role_level("admin") == 3
    end

    test "returns 0 for unknown role" do
      assert Setup.role_level("unknown") == 0
    end
  end

  describe "role_meets_minimum?/2" do
    test "admin meets all minimums" do
      assert Setup.role_meets_minimum?("admin", "guest")
      assert Setup.role_meets_minimum?("admin", "user")
      assert Setup.role_meets_minimum?("admin", "moderator")
      assert Setup.role_meets_minimum?("admin", "admin")
    end

    test "user does not meet moderator minimum" do
      refute Setup.role_meets_minimum?("user", "moderator")
      refute Setup.role_meets_minimum?("user", "admin")
    end

    test "guest meets only guest minimum" do
      assert Setup.role_meets_minimum?("guest", "guest")
      refute Setup.role_meets_minimum?("guest", "user")
    end
  end

  describe "can_view_board?/2" do
    test "guest board visible to nil user" do
      {:ok, board} =
        Content.create_board(%{
          name: "Pub",
          slug: "pub-#{System.unique_integer([:positive])}",
          min_role_to_view: "guest"
        })

      assert Content.can_view_board?(board, nil)
    end

    test "user board not visible to nil user" do
      {:ok, board} =
        Content.create_board(%{
          name: "Users",
          slug: "usr-#{System.unique_integer([:positive])}",
          min_role_to_view: "user"
        })

      refute Content.can_view_board?(board, nil)
    end

    test "user board visible to user", %{user: user} do
      {:ok, board} =
        Content.create_board(%{
          name: "Users",
          slug: "usr-#{System.unique_integer([:positive])}",
          min_role_to_view: "user"
        })

      assert Content.can_view_board?(board, user)
    end

    test "moderator board not visible to user", %{user: user} do
      {:ok, board} =
        Content.create_board(%{
          name: "Mods",
          slug: "mod-#{System.unique_integer([:positive])}",
          min_role_to_view: "moderator"
        })

      refute Content.can_view_board?(board, user)
    end

    test "moderator board visible to moderator", %{moderator: moderator} do
      {:ok, board} =
        Content.create_board(%{
          name: "Mods",
          slug: "mod-#{System.unique_integer([:positive])}",
          min_role_to_view: "moderator"
        })

      assert Content.can_view_board?(board, moderator)
    end

    test "admin board visible to admin", %{admin: admin} do
      {:ok, board} =
        Content.create_board(%{
          name: "Admin",
          slug: "adm-#{System.unique_integer([:positive])}",
          min_role_to_view: "admin"
        })

      assert Content.can_view_board?(board, admin)
    end
  end

  describe "can_post_in_board?/2" do
    test "nil user cannot post" do
      {:ok, board} =
        Content.create_board(%{
          name: "Board",
          slug: "b-#{System.unique_integer([:positive])}",
          min_role_to_post: "user"
        })

      refute Content.can_post_in_board?(board, nil)
    end

    test "active user can post in user-min board", %{user: user} do
      {:ok, board} =
        Content.create_board(%{
          name: "Board",
          slug: "b-#{System.unique_integer([:positive])}",
          min_role_to_post: "user"
        })

      assert Content.can_post_in_board?(board, user)
    end

    test "user cannot post in moderator-min board", %{user: user} do
      {:ok, board} =
        Content.create_board(%{
          name: "Board",
          slug: "b-#{System.unique_integer([:positive])}",
          min_role_to_post: "moderator"
        })

      refute Content.can_post_in_board?(board, user)
    end

    test "moderator can post in moderator-min board", %{moderator: moderator} do
      {:ok, board} =
        Content.create_board(%{
          name: "Board",
          slug: "b-#{System.unique_integer([:positive])}",
          min_role_to_post: "moderator"
        })

      assert Content.can_post_in_board?(board, moderator)
    end
  end

  describe "board_moderator?/2" do
    test "admin is always board mod", %{admin: admin} do
      {:ok, board} =
        Content.create_board(%{name: "Board", slug: "bm-#{System.unique_integer([:positive])}"})

      assert Content.board_moderator?(board, admin)
    end

    test "global moderator is always board mod", %{moderator: moderator} do
      {:ok, board} =
        Content.create_board(%{name: "Board", slug: "bm-#{System.unique_integer([:positive])}"})

      assert Content.board_moderator?(board, moderator)
    end

    test "assigned user is board mod", %{user: user} do
      {:ok, board} =
        Content.create_board(%{name: "Board", slug: "bm-#{System.unique_integer([:positive])}"})

      {:ok, _} = Content.add_board_moderator(board.id, user.id)
      assert Content.board_moderator?(board, user)
    end

    test "random user is not board mod", %{user: user} do
      {:ok, board} =
        Content.create_board(%{name: "Board", slug: "bm-#{System.unique_integer([:positive])}"})

      refute Content.board_moderator?(board, user)
    end

    test "nil user is not board mod" do
      {:ok, board} =
        Content.create_board(%{name: "Board", slug: "bm-#{System.unique_integer([:positive])}"})

      refute Content.board_moderator?(board, nil)
    end
  end

  describe "can_edit_article?/2" do
    setup %{user: user} do
      {:ok, board} =
        Content.create_board(%{name: "Board", slug: "ea-#{System.unique_integer([:positive])}"})

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "Test",
            body: "Body",
            slug: "ea-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          [board.id]
        )

      {:ok, board: board, article: article}
    end

    test "author can edit", %{user: user, article: article} do
      assert Content.can_edit_article?(user, article)
    end

    test "admin can edit", %{admin: admin, article: article} do
      assert Content.can_edit_article?(admin, article)
    end

    test "board mod cannot edit others' articles", %{moderator: moderator, article: article} do
      refute Content.can_edit_article?(moderator, article)
    end

    test "random user cannot edit", %{article: article} do
      refute Content.can_edit_article?(nil, article)
    end
  end

  describe "can_delete_article?/2" do
    setup %{user: user} do
      {:ok, board} =
        Content.create_board(%{name: "Board", slug: "da-#{System.unique_integer([:positive])}"})

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "Test",
            body: "Body",
            slug: "da-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          [board.id]
        )

      {:ok, board: board, article: article}
    end

    test "author can delete", %{user: user, article: article} do
      assert Content.can_delete_article?(user, article)
    end

    test "admin can delete", %{admin: admin, article: article} do
      assert Content.can_delete_article?(admin, article)
    end

    test "board mod can delete", %{board: board, article: article} do
      role = Repo.one!(from(r in Setup.Role, where: r.name == "user"))

      {:ok, mod_user} =
        %Setup.User{}
        |> Setup.User.registration_changeset(%{
          "username" => "bmod_#{System.unique_integer([:positive])}",
          "password" => "Password123!x",
          "password_confirmation" => "Password123!x",
          "role_id" => role.id
        })
        |> Repo.insert()

      mod_user = Repo.preload(mod_user, :role)
      {:ok, _} = Content.add_board_moderator(board.id, mod_user.id)

      assert Content.can_delete_article?(mod_user, article)
    end

    test "random user cannot delete", %{article: article, guest: guest} do
      refute Content.can_delete_article?(guest, article)
    end
  end

  describe "can_pin_article?/2 and can_lock_article?/2" do
    setup %{user: user} do
      {:ok, board} =
        Content.create_board(%{name: "Board", slug: "pl-#{System.unique_integer([:positive])}"})

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "Test",
            body: "Body",
            slug: "pl-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          [board.id]
        )

      {:ok, board: board, article: article}
    end

    test "admin can pin and lock", %{admin: admin, article: article} do
      assert Content.can_pin_article?(admin, article)
      assert Content.can_lock_article?(admin, article)
    end

    test "board mod can pin and lock", %{board: board, article: article} do
      role = Repo.one!(from(r in Setup.Role, where: r.name == "user"))

      {:ok, mod_user} =
        %Setup.User{}
        |> Setup.User.registration_changeset(%{
          "username" => "bmod2_#{System.unique_integer([:positive])}",
          "password" => "Password123!x",
          "password_confirmation" => "Password123!x",
          "role_id" => role.id
        })
        |> Repo.insert()

      mod_user = Repo.preload(mod_user, :role)
      {:ok, _} = Content.add_board_moderator(board.id, mod_user.id)

      assert Content.can_pin_article?(mod_user, article)
      assert Content.can_lock_article?(mod_user, article)
    end

    test "author alone cannot pin or lock", %{user: user, article: article} do
      refute Content.can_pin_article?(user, article)
      refute Content.can_lock_article?(user, article)
    end
  end

  describe "can_delete_comment?/3" do
    setup %{user: user} do
      {:ok, board} =
        Content.create_board(%{name: "Board", slug: "dc-#{System.unique_integer([:positive])}"})

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "Test",
            body: "Body",
            slug: "dc-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          [board.id]
        )

      {:ok, comment} =
        Content.create_comment(%{
          "body" => "A comment",
          "article_id" => article.id,
          "user_id" => user.id
        })

      {:ok, board: board, article: article, comment: comment}
    end

    test "comment author can delete", %{user: user, comment: comment, article: article} do
      assert Content.can_delete_comment?(user, comment, article)
    end

    test "admin can delete", %{admin: admin, comment: comment, article: article} do
      assert Content.can_delete_comment?(admin, comment, article)
    end

    test "board mod can delete", %{board: board, comment: comment, article: article} do
      role = Repo.one!(from(r in Setup.Role, where: r.name == "user"))

      {:ok, mod_user} =
        %Setup.User{}
        |> Setup.User.registration_changeset(%{
          "username" => "bmod3_#{System.unique_integer([:positive])}",
          "password" => "Password123!x",
          "password_confirmation" => "Password123!x",
          "role_id" => role.id
        })
        |> Repo.insert()

      mod_user = Repo.preload(mod_user, :role)
      {:ok, _} = Content.add_board_moderator(board.id, mod_user.id)

      assert Content.can_delete_comment?(mod_user, comment, article)
    end
  end

  describe "toggle_pin_article/1" do
    test "toggles pinned status", %{user: user} do
      {:ok, board} =
        Content.create_board(%{name: "Board", slug: "tp-#{System.unique_integer([:positive])}"})

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "Pin Test",
            body: "Body",
            slug: "tp-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          [board.id]
        )

      refute article.pinned
      {:ok, pinned} = Content.toggle_pin_article(article)
      assert pinned.pinned
      {:ok, unpinned} = Content.toggle_pin_article(pinned)
      refute unpinned.pinned
    end
  end

  describe "toggle_lock_article/1" do
    test "toggles locked status", %{user: user} do
      {:ok, board} =
        Content.create_board(%{name: "Board", slug: "tl-#{System.unique_integer([:positive])}"})

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "Lock Test",
            body: "Body",
            slug: "tl-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          [board.id]
        )

      refute article.locked
      {:ok, locked} = Content.toggle_lock_article(article)
      assert locked.locked
      {:ok, unlocked} = Content.toggle_lock_article(locked)
      refute unlocked.locked
    end
  end

  describe "list_visible_top_boards/1" do
    test "guest sees only guest-visible boards" do
      {:ok, _pub} =
        Content.create_board(%{
          name: "Public",
          slug: "vt-pub-#{System.unique_integer([:positive])}",
          min_role_to_view: "guest"
        })

      {:ok, _usr} =
        Content.create_board(%{
          name: "Users Only",
          slug: "vt-usr-#{System.unique_integer([:positive])}",
          min_role_to_view: "user"
        })

      boards = Content.list_visible_top_boards(nil)
      names = Enum.map(boards, & &1.name)
      assert "Public" in names
      refute "Users Only" in names
    end

    test "user sees user-visible boards", %{user: user} do
      {:ok, _pub} =
        Content.create_board(%{
          name: "PubV",
          slug: "vtu-pub-#{System.unique_integer([:positive])}",
          min_role_to_view: "guest"
        })

      {:ok, _usr} =
        Content.create_board(%{
          name: "UsrV",
          slug: "vtu-usr-#{System.unique_integer([:positive])}",
          min_role_to_view: "user"
        })

      {:ok, _mod} =
        Content.create_board(%{
          name: "ModV",
          slug: "vtu-mod-#{System.unique_integer([:positive])}",
          min_role_to_view: "moderator"
        })

      boards = Content.list_visible_top_boards(user)
      names = Enum.map(boards, & &1.name)
      assert "PubV" in names
      assert "UsrV" in names
      refute "ModV" in names
    end
  end

  describe "list_visible_sub_boards/2" do
    test "filters sub-boards by role" do
      {:ok, parent} =
        Content.create_board(%{
          name: "Parent",
          slug: "vs-p-#{System.unique_integer([:positive])}"
        })

      {:ok, _pub} =
        Content.create_board(%{
          name: "SubPub",
          slug: "vs-pub-#{System.unique_integer([:positive])}",
          parent_id: parent.id,
          min_role_to_view: "guest"
        })

      {:ok, _usr} =
        Content.create_board(%{
          name: "SubUsr",
          slug: "vs-usr-#{System.unique_integer([:positive])}",
          parent_id: parent.id,
          min_role_to_view: "user"
        })

      subs = Content.list_visible_sub_boards(parent, nil)
      assert length(subs) == 1
      assert hd(subs).name == "SubPub"
    end
  end
end
