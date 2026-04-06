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

      assert {:ok, 1} =
               Delivery.enqueue(activity, "https://local/ap/users/alice", [
                 "https://a.example/inbox"
               ])

      job = Repo.one!(DeliveryJob)
      assert Jason.decode!(job.activity_json) == activity
    end

    test "skips duplicate pending job for same inbox+actor" do
      activity1 = Jason.encode!(%{"type" => "Create", "id" => "1"})
      activity2 = Jason.encode!(%{"type" => "Create", "id" => "2"})
      actor = "https://local/ap/users/dedup"
      inbox = "https://dedup.example/inbox"

      assert {:ok, 1} = Delivery.enqueue(activity1, actor, [inbox])
      assert {:ok, 1} = Delivery.enqueue(activity2, actor, [inbox])

      jobs =
        Repo.all(from(j in DeliveryJob, where: j.inbox_url == ^inbox and j.actor_uri == ^actor))

      assert length(jobs) == 1
    end

    test "allows new job after previous one is delivered" do
      activity1 = Jason.encode!(%{"type" => "Create", "id" => "1"})
      activity2 = Jason.encode!(%{"type" => "Create", "id" => "2"})
      actor = "https://local/ap/users/dedup2"
      inbox = "https://dedup2.example/inbox"

      assert {:ok, 1} = Delivery.enqueue(activity1, actor, [inbox])

      # Mark the job as delivered
      job = Repo.one!(from(j in DeliveryJob, where: j.inbox_url == ^inbox))
      job |> DeliveryJob.mark_delivered() |> Repo.update!()

      # Now a new job can be inserted
      assert {:ok, 1} = Delivery.enqueue(activity2, actor, [inbox])

      jobs =
        Repo.all(from(j in DeliveryJob, where: j.inbox_url == ^inbox and j.actor_uri == ^actor))

      assert length(jobs) == 2
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

      # Clear auto-created jobs (federation runs synchronously in test)
      # to test enqueue_for_article directly
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
          min_role_to_view: "user"
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

      Repo.delete_all(DeliveryJob)

      article = Repo.preload(article, [:boards, :user])
      activity = Jason.encode!(%{"type" => "Create"})

      # Board is private, so its followers should not be included
      assert {:ok, 0} = Delivery.enqueue_for_article(activity, user_uri, article)
    end
  end

  describe "purge_completed_jobs/0" do
    test "deletes old delivered jobs" do
      old = DateTime.utc_now() |> DateTime.add(-8, :day) |> DateTime.truncate(:second)

      %DeliveryJob{}
      |> DeliveryJob.create_changeset(%{
        activity_json: "{}",
        inbox_url: "https://remote.example/inbox",
        actor_uri: "https://local.example/ap/users/alice"
      })
      |> Ecto.Changeset.change(%{status: "delivered", inserted_at: old})
      |> Repo.insert!()

      assert Delivery.purge_completed_jobs() == 1
      assert Repo.all(DeliveryJob) == []
    end

    test "keeps recent delivered jobs" do
      recent = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second)

      %DeliveryJob{}
      |> DeliveryJob.create_changeset(%{
        activity_json: "{}",
        inbox_url: "https://remote.example/inbox",
        actor_uri: "https://local.example/ap/users/alice"
      })
      |> Ecto.Changeset.change(%{status: "delivered", inserted_at: recent})
      |> Repo.insert!()

      assert Delivery.purge_completed_jobs() == 0
      assert length(Repo.all(DeliveryJob)) == 1
    end

    test "deletes old abandoned jobs" do
      old = DateTime.utc_now() |> DateTime.add(-31, :day) |> DateTime.truncate(:second)

      %DeliveryJob{}
      |> DeliveryJob.create_changeset(%{
        activity_json: "{}",
        inbox_url: "https://remote.example/inbox",
        actor_uri: "https://local.example/ap/users/alice"
      })
      |> Ecto.Changeset.change(%{status: "abandoned", inserted_at: old})
      |> Repo.insert!()

      assert Delivery.purge_completed_jobs() == 1
      assert Repo.all(DeliveryJob) == []
    end

    test "keeps pending and failed jobs" do
      old = DateTime.utc_now() |> DateTime.add(-31, :day) |> DateTime.truncate(:second)

      for status <- ["pending", "failed"] do
        %DeliveryJob{}
        |> DeliveryJob.create_changeset(%{
          activity_json: "{}",
          inbox_url: "https://remote.example/inbox-#{status}",
          actor_uri: "https://local.example/ap/users/alice"
        })
        |> Ecto.Changeset.change(%{status: status, inserted_at: old})
        |> Repo.insert!()
      end

      assert Delivery.purge_completed_jobs() == 0
      assert length(Repo.all(DeliveryJob)) == 2
    end
  end

  describe "deliver_flag/2" do
    test "creates a delivery job with site actor URI" do
      remote = create_remote_actor()
      flag_json = Jason.encode!(%{"type" => "Flag", "actor" => "https://local/ap/site"})

      assert {:ok, 1} = Delivery.deliver_flag(flag_json, remote)

      job = Repo.one!(DeliveryJob)
      site_uri = Federation.actor_uri(:site, nil)
      assert job.actor_uri == site_uri
      assert job.inbox_url == remote.inbox
    end

    test "uses shared_inbox when available" do
      remote = create_remote_actor(%{shared_inbox: "https://remote.example/inbox"})
      flag_json = Jason.encode!(%{"type" => "Flag"})

      assert {:ok, 1} = Delivery.deliver_flag(flag_json, remote)

      job = Repo.one!(DeliveryJob)
      assert job.inbox_url == "https://remote.example/inbox"
    end
  end

  describe "deliver_block/3" do
    test "creates a delivery job with provided actor URI" do
      user = create_user()
      remote = create_remote_actor()
      actor_uri = Federation.actor_uri(:user, user.username)
      block_json = Jason.encode!(%{"type" => "Block"})

      assert {:ok, 1} = Delivery.deliver_block(block_json, remote, actor_uri)

      job = Repo.one!(DeliveryJob)
      assert job.actor_uri == actor_uri
      assert job.inbox_url == remote.inbox
    end

    test "uses shared_inbox when available" do
      user = create_user()
      remote = create_remote_actor(%{shared_inbox: "https://remote.example/inbox"})
      actor_uri = Federation.actor_uri(:user, user.username)
      block_json = Jason.encode!(%{"type" => "Block"})

      assert {:ok, 1} = Delivery.deliver_block(block_json, remote, actor_uri)

      job = Repo.one!(DeliveryJob)
      assert job.inbox_url == "https://remote.example/inbox"
    end
  end

  describe "deliver_one/1 telemetry" do
    test "emits start and stop telemetry events on delivery attempt" do
      test_pid = self()
      ref = make_ref()

      handler = fn event, measurements, metadata, _ ->
        send(test_pid, {ref, event, measurements, metadata})
      end

      :telemetry.attach_many(
        "test-delivery-telemetry-#{ref |> inspect()}",
        [
          [:baudrate, :federation, :delivery, :start],
          [:baudrate, :federation, :delivery, :stop]
        ],
        handler,
        nil
      )

      on_exit(fn ->
        :telemetry.detach("test-delivery-telemetry-#{ref |> inspect()}")
      end)

      {:ok, job} =
        %DeliveryJob{}
        |> DeliveryJob.create_changeset(%{
          activity_json: ~s({"type":"Create"}),
          inbox_url: "https://telemetry-test.example/inbox",
          actor_uri: "https://local.example/ap/users/test"
        })
        |> Repo.insert()

      # deliver_one will fail (no key found), but telemetry should still fire
      Delivery.deliver_one(job)

      assert_receive {^ref, [:baudrate, :federation, :delivery, :start], %{system_time: _},
                      %{inbox_url: "https://telemetry-test.example/inbox"}}

      assert_receive {^ref, [:baudrate, :federation, :delivery, :stop], %{duration: duration},
                      %{status: :failed}}

      assert is_integer(duration)
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

    test "returns error for local user URI with non-existent username" do
      # Ensures no panic (Ecto.NoResultsError) when a user is deleted after a
      # delivery job is created — should gracefully return :unknown_actor.
      actor_uri = Federation.actor_uri(:user, "deleted_user_#{System.unique_integer([:positive])}")
      assert {:error, :unknown_actor} = Delivery.get_private_key(actor_uri)
    end

    test "returns error for local board URI with non-existent slug" do
      actor_uri = Federation.actor_uri(:board, "deleted-board-#{System.unique_integer([:positive])}")
      assert {:error, :unknown_actor} = Delivery.get_private_key(actor_uri)
    end
  end

  describe "send_accept/3" do
    setup do
      Req.Test.stub(Baudrate.Federation.HTTPClient, fn conn ->
        Plug.Conn.send_resp(conn, 202, "Accepted")
      end)

      :ok
    end

    test "sends Accept(Follow) signed POST to remote actor inbox" do
      user = create_user()
      remote = create_remote_actor()
      actor_uri = Federation.actor_uri(:user, user.username)

      follow_activity = %{
        "type" => "Follow",
        "id" => "https://remote.example/activities/follow-#{System.unique_integer([:positive])}",
        "actor" => remote.ap_id,
        "object" => actor_uri
      }

      assert {:ok, _} = Delivery.send_accept(follow_activity, actor_uri, remote)
    end

    test "returns error when actor has no keypair" do
      remote = create_remote_actor()
      actor_uri = Federation.actor_uri(:user, "nonexistent_#{System.unique_integer([:positive])}")

      follow_activity = %{"type" => "Follow", "id" => "https://remote.example/f/1"}

      assert {:error, :unknown_actor} = Delivery.send_accept(follow_activity, actor_uri, remote)
    end
  end

  describe "send_reject/3" do
    setup do
      Req.Test.stub(Baudrate.Federation.HTTPClient, fn conn ->
        Plug.Conn.send_resp(conn, 202, "Accepted")
      end)

      :ok
    end

    test "sends Reject(Follow) signed POST to remote actor inbox" do
      user = create_user()
      remote = create_remote_actor()
      actor_uri = Federation.actor_uri(:user, user.username)

      follow_activity = %{
        "type" => "Follow",
        "id" => "https://remote.example/activities/follow-#{System.unique_integer([:positive])}",
        "actor" => remote.ap_id,
        "object" => actor_uri
      }

      assert {:ok, _} = Delivery.send_reject(follow_activity, actor_uri, remote)
    end

    test "returns error when actor has no keypair" do
      remote = create_remote_actor()
      actor_uri = Federation.actor_uri(:board, "nonexistent-#{System.unique_integer([:positive])}")

      follow_activity = %{"type" => "Follow", "id" => "https://remote.example/f/1"}

      assert {:error, :unknown_actor} = Delivery.send_reject(follow_activity, actor_uri, remote)
    end
  end
end
