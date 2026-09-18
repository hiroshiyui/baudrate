defmodule Baudrate.AccountMigration.ReadOnlyTest do
  @moduledoc """
  A moved account is read-only, enforced at the context boundary so no path
  (LiveView, a client speaking the protocol directly, a future API) can post
  or interact for it (ADR 0025). Undoing, deleting, following and reading stay
  allowed.
  """

  use Baudrate.DataCase, async: false

  import Ecto.Query

  alias Baudrate.{Auth, Content, Federation, Messaging, Repo, Setup}
  alias Baudrate.Federation.RemoteActor

  setup do
    Setup.seed_roles_and_permissions()
    author = create_user()
    mover = create_user()

    board =
      %Content.Board{}
      |> Content.Board.changeset(%{name: "RO", slug: "ro-#{System.unique_integer([:positive])}"})
      |> Repo.insert!()

    {:ok, %{article: article}} =
      Content.create_article(
        %{
          title: "Poll",
          body: "Body",
          slug: "ro-#{System.unique_integer([:positive])}",
          user_id: author.id
        },
        [board.id],
        poll: %{
          mode: "single",
          options: [%{text: "Yes", position: 0}, %{text: "No", position: 1}]
        }
      )

    {:ok, mover_article} =
      Content.create_article(
        %{
          title: "Mine",
          body: "Body",
          slug: "ro-#{System.unique_integer([:positive])}",
          user_id: mover.id
        },
        [board.id]
      )
      |> then(fn {:ok, %{article: a}} -> {:ok, a} end)

    # Interactions that existed before the move.
    {:ok, _like} = Content.toggle_article_like(mover.id, article.id)

    Repo.update_all(from(u in Setup.User, where: u.id == ^mover.id),
      set: [moved_to: "https://new.example/users/mover"]
    )

    %{
      author: author,
      mover: Repo.reload!(mover) |> Repo.preload(:role),
      board: board,
      article: Repo.preload(article, poll: :options),
      mover_article: mover_article
    }
  end

  defp create_user do
    role = Repo.one!(from(r in Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => "ro_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  test "cannot create articles; a comment forwarded by someone else is not blocked",
       %{mover: mover, board: board} do
    attrs = %{title: "New", body: "Body", slug: "ro-new-#{System.unique_integer([:positive])}"}

    assert {:error, :account, :account_moved, _} =
             Content.create_article(Map.put(attrs, :user_id, mover.id), [board.id])

    assert {:error, :account, :account_moved, _} =
             Content.create_article(Map.put(attrs, "user_id", mover.id), [])

    assert {:ok, _} =
             Content.create_article(Map.put(attrs, :user_id, mover.id), [board.id],
               forwarded_comment: true
             )
  end

  test "cannot edit its articles, while an admin still can",
       %{mover: mover, mover_article: article} do
    assert {:error, :account_moved} = Content.update_article(article, %{title: "Edited"}, mover)

    admin = create_user()

    assert {:ok, %{title: "By admin"}} =
             Content.update_article(article, %{title: "By admin"}, admin)
  end

  test "cannot comment", %{mover: mover, article: article} do
    assert {:error, :account_moved} =
             Content.create_comment(%{body: "Hi", article_id: article.id, user_id: mover.id})
  end

  test "cannot like or boost, but can undo an existing like", %{mover: mover, article: article} do
    assert {:ok, :removed} = Content.toggle_article_like(mover.id, article.id)
    assert {:error, :account_moved} = Content.toggle_article_like(mover.id, article.id)
    assert {:error, :account_moved} = Content.toggle_article_boost(mover.id, article.id)
  end

  test "cannot like or boost comments", %{author: author, mover: mover, article: article} do
    {:ok, comment} =
      Content.create_comment(%{body: "Hi", article_id: article.id, user_id: author.id})

    assert {:error, :account_moved} = Content.toggle_comment_like(mover.id, comment.id)
    assert {:error, :account_moved} = Content.toggle_comment_boost(mover.id, comment.id)
  end

  test "cannot vote in polls", %{mover: mover, article: article} do
    [option | _] = article.poll.options
    assert {:error, :account_moved} = Content.cast_vote(article.poll, mover, [option.id])
  end

  test "cannot forward to a board", %{mover: mover, article: article} do
    other_board =
      %Content.Board{}
      |> Content.Board.changeset(%{
        name: "RO2",
        slug: "ro2-#{System.unique_integer([:positive])}"
      })
      |> Repo.insert!()

    assert {:error, :unauthorized} = Content.forward_article_to_board(article, other_board, mover)
    refute Auth.can_create_content?(mover)
  end

  test "cannot send DMs or generate invites", %{mover: mover, author: author} do
    refute Messaging.can_send_dm?(mover, author)
    assert {:error, :account_moved} = Auth.can_generate_invite?(mover)
    assert {:error, :account_moved} = Auth.generate_invite_code(mover)
  end

  test "cannot like, boost or reply to feed items", %{mover: mover} do
    actor =
      %RemoteActor{}
      |> RemoteActor.changeset(%{
        ap_id: "https://remote.example/users/ro-#{System.unique_integer([:positive])}",
        username: "ro_actor_#{System.unique_integer([:positive])}",
        domain: "remote.example",
        public_key_pem: "-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----",
        inbox: "https://remote.example/inbox",
        actor_type: "Person",
        fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert!()

    {:ok, follow} = Federation.create_user_follow(mover, actor)
    {:ok, _} = Federation.accept_user_follow(follow.ap_id)
    uid = System.unique_integer([:positive])

    {:ok, item} =
      Federation.create_timeline_item(%{
        remote_actor_id: actor.id,
        activity_type: "Create",
        object_type: "Note",
        ap_id: "https://remote.example/notes/#{uid}",
        body: "Hello",
        body_html: "<p>Hello</p>",
        source_url: "https://remote.example/notes/#{uid}",
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    assert {:error, :account_moved} = Federation.toggle_timeline_item_like(mover, item.id)
    assert {:error, :account_moved} = Federation.toggle_timeline_item_boost(mover, item.id)
    assert {:error, :account_moved} = Federation.create_timeline_item_reply(item, mover, "Hi")
  end

  test "a moved account cannot be followed locally", %{author: author, mover: mover} do
    assert {:error, :account_moved} = Federation.create_local_follow(author, mover)
  end

  test "it can still follow others and delete its own articles",
       %{author: author, mover: mover, mover_article: article} do
    assert {:ok, _} = Federation.create_local_follow(mover, author)
    assert {:ok, _} = Content.soft_delete_article(article)
  end
end
