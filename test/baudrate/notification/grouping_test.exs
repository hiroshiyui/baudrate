defmodule Baudrate.Notification.GroupingTest do
  @moduledoc """
  Likes and boosts of one thing are one entry on `/notifications` (6B), and
  the page can be filtered by category.

  Grouping happens in the query, before paging, so the badge
  (`unread_count/1`) and the page count the same entries and a group never
  splits across two pages.
  """

  use Baudrate.DataCase, async: true

  alias Baudrate.Content
  alias Baudrate.Notification
  alias Baudrate.Notification.Notification, as: NotificationSchema
  alias Baudrate.Notification.PubSub

  setup do
    Baudrate.Setup.seed_roles_and_permissions()
    author = create_user("author")

    board =
      %Content.Board{}
      |> Content.Board.changeset(%{name: "G", slug: "g-#{System.unique_integer([:positive])}"})
      |> Repo.insert!()

    %{author: author, first: article!(author, board), second: article!(author, board)}
  end

  describe "list_notification_groups/2" do
    test "likes of one article are one group, newest actors first", %{
      author: author,
      first: first
    } do
      likers = for i <- 1..5, do: create_user("liker#{i}")

      for {liker, i} <- Enum.with_index(likers),
          do: notify!(author, "article_liked", liker, first, i)

      assert %{groups: [group], total: 1} = Notification.list_notification_groups(author.id)
      assert group.count == 5
      assert group.unread
      assert length(group.ids) == 5

      assert Enum.map(group.actors, & &1.actor_user_id) ==
               likers |> Enum.reverse() |> Enum.take(3) |> Enum.map(& &1.id)

      assert group.notification.actor_user.id == List.last(likers).id
    end

    test "likes of different articles, and likes against boosts, stay apart", %{
      author: author,
      first: first,
      second: second
    } do
      a = create_user("a")
      b = create_user("b")
      notify!(author, "article_liked", a, first, 1)
      notify!(author, "article_liked", b, first, 2)
      notify!(author, "article_liked", a, second, 3)
      notify!(author, "article_boosted", a, first, 4)

      %{groups: groups} = Notification.list_notification_groups(author.id)

      assert Enum.map(groups, &{&1.notification.type, &1.count}) ==
               [{"article_boosted", 1}, {"article_liked", 1}, {"article_liked", 2}]
    end

    test "replies are never grouped", %{author: author, first: first} do
      a = create_user("a")
      notify!(author, "mention", a, first, 1)
      notify!(author, "new_follower", a, nil, 2)
      notify!(author, "new_follower", create_user("b"), nil, 3)

      assert %{total: 3} = Notification.list_notification_groups(author.id)
    end

    test "a group never splits across a page boundary", %{
      author: author,
      first: first,
      second: second
    } do
      # One big group, then enough single entries to push it to page 2.
      for i <- 1..4, do: notify!(author, "article_liked", create_user("l#{i}"), first, i)
      for i <- 1..3, do: notify!(author, "new_follower", create_user("f#{i}"), nil, 10 + i)
      notify!(author, "article_liked", create_user("x"), second, 20)

      page1 = Notification.list_notification_groups(author.id, per_page: 3, page: 1)
      page2 = Notification.list_notification_groups(author.id, per_page: 3, page: 2)

      assert page1.total == 5
      assert page2.total_pages == 2
      assert [%{count: 1}, %{count: 4}] = page2.groups
    end

    test "is filtered by category", %{author: author, first: first} do
      notify!(author, "article_liked", create_user("l"), first, 1)
      notify!(author, "mention", create_user("m"), first, 2)
      notify!(author, "new_follower", create_user("f"), nil, 3)

      types = NotificationSchema.category_types("discussion")

      assert %{groups: [%{notification: %{type: "mention"}}]} =
               Notification.list_notification_groups(author.id, types: types)
    end
  end

  describe "unread_count/1" do
    test "counts groups, so the badge matches the page", %{author: author, first: first} do
      for i <- 1..4, do: notify!(author, "article_liked", create_user("l#{i}"), first, i)
      notify!(author, "mention", create_user("m"), first, 10)

      assert Notification.unread_count(author.id) == 2

      assert Notification.unread_count(author.id) ==
               Enum.count(Notification.list_notification_groups(author.id).groups, & &1.unread)
    end
  end

  describe "mark_group_as_read/1" do
    test "marks the whole group, and broadcasts once", %{author: author, first: first} do
      notifs = for i <- 1..3, do: notify!(author, "article_liked", create_user("l#{i}"), first, i)
      other = notify!(author, "article_liked", create_user("o"), nil, 9)
      PubSub.subscribe_user(author.id)

      assert Notification.mark_group_as_read(hd(notifs)) == 3
      assert Notification.unread_count(author.id) == 1
      assert Repo.get!(NotificationSchema, other.id).read == false
      assert_receive {:notification_read, _}
      refute_receive {:notification_read, _}
    end

    test "an ungrouped notification marks only itself", %{author: author, first: first} do
      one = notify!(author, "mention", create_user("a"), first, 1)
      two = notify!(author, "mention", create_user("b"), first, 2)

      assert Notification.mark_group_as_read(one) == 1
      assert Repo.get!(NotificationSchema, two.id).read == false
    end

    test "never reaches another member's notifications", %{author: author, first: first} do
      someone = create_user("someone")
      liker = create_user("liker")
      mine = notify!(author, "article_liked", liker, first, 1)
      theirs = notify!(someone, "article_liked", liker, first, 2)

      Notification.mark_group_as_read(mine)
      assert Repo.get!(NotificationSchema, theirs.id).read == false
    end
  end

  describe "categories/0" do
    # A new type in no category would never appear under any filter but "All".
    test "put every valid type in exactly one category" do
      categorized = Enum.flat_map(NotificationSchema.categories(), &elem(&1, 1))

      assert Enum.sort(categorized) == Enum.sort(NotificationSchema.valid_types())
      assert categorized == Enum.uniq(categorized)
    end

    test "an unknown category has no types" do
      assert NotificationSchema.category_types("nope") == nil
      assert NotificationSchema.category_types(nil) == nil
    end
  end

  # --- helpers ---

  defp notify!(recipient, type, actor, article, n) do
    at = DateTime.add(~U[2026-01-01 00:00:00Z], n * 60, :second)

    Repo.insert!(%NotificationSchema{
      type: type,
      user_id: recipient.id,
      actor_user_id: actor.id,
      article_id: article && article.id,
      inserted_at: at,
      updated_at: at
    })
  end

  defp article!(author, board) do
    {:ok, %{article: article}} =
      Content.create_article(
        %{
          title: "Liked",
          body: "Body",
          slug: "liked-#{System.unique_integer([:positive])}",
          user_id: author.id
        },
        [board.id]
      )

    article
  end

  defp create_user(prefix) do
    role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %Baudrate.Setup.User{}
      |> Baudrate.Setup.User.registration_changeset(%{
        "username" => "#{prefix}_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    user
  end
end
