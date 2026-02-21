defmodule Baudrate.Federation.DeliveryTest do
  use Baudrate.DataCase, async: false

  alias Baudrate.Federation
  alias Baudrate.Federation.{Delivery, DeliveryJob, KeyStore, RemoteActor}

  setup do
    Baudrate.Setup.seed_roles_and_permissions()
    :ok
  end

  defp create_user do
    role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %Baudrate.Setup.User{}
      |> Baudrate.Setup.User.registration_changeset(%{
        "username" => "del_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    {:ok, user} = KeyStore.ensure_user_keypair(user)
    Repo.preload(user, :role)
  end

  defp create_remote_actor(attrs \\ %{}) do
    uid = System.unique_integer([:positive])

    default = %{
      ap_id: "https://remote.example/users/actor-#{uid}",
      username: "actor_#{uid}",
      domain: "remote.example",
      public_key_pem: elem(KeyStore.generate_keypair(), 0),
      inbox: "https://remote.example/users/actor-#{uid}/inbox",
      actor_type: "Person",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    {:ok, actor} =
      %RemoteActor{}
      |> RemoteActor.changeset(Map.merge(default, attrs))
      |> Repo.insert()

    actor
  end

  defp create_board(slug \\ nil) do
    slug = slug || "board-#{System.unique_integer([:positive])}"

    board =
      %Baudrate.Content.Board{}
      |> Baudrate.Content.Board.changeset(%{name: "Test Board", slug: slug})
      |> Repo.insert!()

    {:ok, board} = KeyStore.ensure_board_keypair(board)
    board
  end

  defp create_follower(actor_uri, remote_actor) do
    Federation.create_follower(
      actor_uri,
      remote_actor,
      "https://remote.example/activities/follow-#{System.unique_integer([:positive])}"
    )
  end

  describe "enqueue/3" do
    test "creates delivery jobs for each inbox" do
      activity = Jason.encode!(%{"type" => "Create", "actor" => "https://local/ap/users/alice"})
      inboxes = ["https://a.example/inbox", "https://b.example/inbox"]

      assert {:ok, 2} = Delivery.enqueue(activity, "https://local/ap/users/alice", inboxes)

      jobs = Repo.all(DeliveryJob)
      assert length(jobs) == 2
      assert Enum.all?(jobs, &(&1.status == "pending"))
    end

    test "deduplicates inbox URLs" do
      activity = Jason.encode!(%{"type" => "Create"})
      inboxes = ["https://a.example/inbox", "https://a.example/inbox", "https://b.example/inbox"]

      assert {:ok, 2} = Delivery.enqueue(activity, "https://local/ap/users/alice", inboxes)

      jobs = Repo.all(DeliveryJob)
      assert length(jobs) == 2
    end

    test "accepts activity as map" do
      activity = %{"type" => "Create", "actor" => "https://local/ap/users/alice"}

      assert {:ok, 1} = Delivery.enqueue(activity, "https://local/ap/users/alice", ["https://a.example/inbox"])

      job = Repo.one!(DeliveryJob)
      assert Jason.decode!(job.activity_json) == activity
    end
  end

  describe "resolve_follower_inboxes/1" do
    test "returns individual inbox when no shared inbox" do
      user = create_user()
      actor_uri = Federation.actor_uri(:user, user.username)
      remote = create_remote_actor()
      create_follower(actor_uri, remote)

      inboxes = Delivery.resolve_follower_inboxes(actor_uri)

      assert length(inboxes) == 1
      assert hd(inboxes) == remote.inbox
    end

    test "uses shared inbox when available" do
      user = create_user()
      actor_uri = Federation.actor_uri(:user, user.username)

      remote =
        create_remote_actor(%{
          shared_inbox: "https://remote.example/inbox"
        })

      create_follower(actor_uri, remote)

      inboxes = Delivery.resolve_follower_inboxes(actor_uri)

      assert inboxes == ["https://remote.example/inbox"]
    end

    test "deduplicates shared inboxes across multiple followers" do
      user = create_user()
      actor_uri = Federation.actor_uri(:user, user.username)

      remote1 =
        create_remote_actor(%{
          shared_inbox: "https://remote.example/inbox"
        })

      remote2 =
        create_remote_actor(%{
          shared_inbox: "https://remote.example/inbox"
        })

      create_follower(actor_uri, remote1)
      create_follower(actor_uri, remote2)

      inboxes = Delivery.resolve_follower_inboxes(actor_uri)

      assert length(inboxes) == 1
      assert hd(inboxes) == "https://remote.example/inbox"
    end

    test "returns empty list when no followers" do
      user = create_user()
      actor_uri = Federation.actor_uri(:user, user.username)

      assert Delivery.resolve_follower_inboxes(actor_uri) == []
    end
  end

  describe "enqueue_for_followers/2" do
    test "enqueues jobs for all follower inboxes" do
      user = create_user()
      actor_uri = Federation.actor_uri(:user, user.username)
      remote = create_remote_actor()
      create_follower(actor_uri, remote)

      activity = Jason.encode!(%{"type" => "Create"})
      assert {:ok, 1} = Delivery.enqueue_for_followers(activity, actor_uri)

      job = Repo.one!(DeliveryJob)
      assert job.inbox_url == remote.inbox
    end

    test "returns 0 when no followers" do
      user = create_user()
      actor_uri = Federation.actor_uri(:user, user.username)

      activity = Jason.encode!(%{"type" => "Create"})
      assert {:ok, 0} = Delivery.enqueue_for_followers(activity, actor_uri)
    end
  end

  describe "enqueue_for_article/3" do
    test "collects inboxes from user followers and board followers" do
      user = create_user()
      board = create_board()
      user_uri = Federation.actor_uri(:user, user.username)
      board_uri = Federation.actor_uri(:board, board.slug)

      user_follower = create_remote_actor()
      board_follower = create_remote_actor()
      create_follower(user_uri, user_follower)
      create_follower(board_uri, board_follower)

      slug = "art-#{System.unique_integer([:positive])}"

      {:ok, %{article: article}} =
        Baudrate.Content.create_article(
          %{title: "Test", body: "Body", slug: slug, user_id: user.id},
          [board.id]
        )

      # Wait for auto-triggered delivery
      Process.sleep(100)

      # Clear auto-created jobs to test enqueue_for_article directly
      Repo.delete_all(DeliveryJob)

      article = Repo.preload(article, [:boards, :user])
      activity = Jason.encode!(%{"type" => "Create"})

      assert {:ok, count} = Delivery.enqueue_for_article(activity, user_uri, article)
      assert count == 2

      jobs = Repo.all(DeliveryJob)
      inbox_urls = Enum.map(jobs, & &1.inbox_url) |> Enum.sort()
      expected = [board_follower.inbox, user_follower.inbox] |> Enum.sort()
      assert inbox_urls == expected
    end

    test "deduplicates shared inboxes across user and board followers" do
      user = create_user()
      board = create_board()
      user_uri = Federation.actor_uri(:user, user.username)
      board_uri = Federation.actor_uri(:board, board.slug)

      # Same remote actor follows both user and board
      remote = create_remote_actor(%{shared_inbox: "https://remote.example/inbox"})
      create_follower(user_uri, remote)
      create_follower(board_uri, remote)

      slug = "art-#{System.unique_integer([:positive])}"

      {:ok, %{article: article}} =
        Baudrate.Content.create_article(
          %{title: "Test", body: "Body", slug: slug, user_id: user.id},
          [board.id]
        )

      Process.sleep(100)
      Repo.delete_all(DeliveryJob)

      article = Repo.preload(article, [:boards, :user])
      activity = Jason.encode!(%{"type" => "Create"})

      assert {:ok, 1} = Delivery.enqueue_for_article(activity, user_uri, article)
    end

    test "skips private boards" do
      user = create_user()
      board_uri_unused = "private-#{System.unique_integer([:positive])}"

      private_board =
        %Baudrate.Content.Board{}
        |> Baudrate.Content.Board.changeset(%{
          name: "Private Board",
          slug: board_uri_unused,
          visibility: "private"
        })
        |> Repo.insert!()

      {:ok, private_board} = KeyStore.ensure_board_keypair(private_board)

      board_uri = Federation.actor_uri(:board, private_board.slug)
      remote = create_remote_actor()
      create_follower(board_uri, remote)

      user_uri = Federation.actor_uri(:user, user.username)

      slug = "art-#{System.unique_integer([:positive])}"

      {:ok, %{article: article}} =
        Baudrate.Content.create_article(
          %{title: "Test", body: "Body", slug: slug, user_id: user.id},
          [private_board.id]
        )

      Process.sleep(100)
      Repo.delete_all(DeliveryJob)

      article = Repo.preload(article, [:boards, :user])
      activity = Jason.encode!(%{"type" => "Create"})

      # Board is private, so its followers should not be included
      assert {:ok, 0} = Delivery.enqueue_for_article(activity, user_uri, article)
    end
  end

  describe "get_private_key/1" do
    test "retrieves user private key" do
      user = create_user()
      actor_uri = Federation.actor_uri(:user, user.username)

      assert {:ok, pem} = Delivery.get_private_key(actor_uri)
      assert pem =~ "BEGIN RSA PRIVATE KEY"
    end

    test "retrieves board private key" do
      board = create_board()
      actor_uri = Federation.actor_uri(:board, board.slug)

      assert {:ok, pem} = Delivery.get_private_key(actor_uri)
      assert pem =~ "BEGIN RSA PRIVATE KEY"
    end

    test "returns error for unknown actor" do
      assert {:error, :unknown_actor} = Delivery.get_private_key("https://unknown.example/actor")
    end
  end
end
