defmodule Baudrate.Federation.ActorUpdatesTest do
  @moduledoc """
  Phase 3D: a change followers can see reaches them, and a change they cannot
  see costs nothing.

  `Federation.update_actor/3` decides by comparing the **rendered actor
  document** rather than a list of fields, which is the property worth
  pinning: a field added to `ActorRenderer` federates without anybody
  remembering to come back here, and a field that is not in the document —
  a signature, a notification preference, a narrowed `dm_access` — sends no
  `Update` at all. An `Update` fans out to every follower's inbox, so "sends
  nothing" is as much the requirement as "sends something".

  The closed-poll sweep is here too because it is the same shape: the only
  place that treats a poll's closing as an event, exactly once.
  """

  use Baudrate.DataCase, async: false

  alias Baudrate.Auth
  alias Baudrate.Content
  alias Baudrate.Content.Board
  alias Baudrate.Federation
  alias Baudrate.Federation.{DeliveryJob, RemoteActor}
  alias Baudrate.Setup

  setup do
    Setup.seed_roles_and_permissions()

    user = create_user()
    follower = create_remote_actor()
    follow(Federation.actor_uri(:user, user.username), follower)

    board = create_board(ap_enabled: true)
    board_follower = create_remote_actor()
    follow(Federation.actor_uri(:board, board.slug), board_follower)

    Repo.delete_all(DeliveryJob)

    %{user: user, follower: follower, board: board, board_follower: board_follower}
  end

  describe "a profile change followers can see" do
    test "a new display name sends Update(Person)", ctx do
      {:ok, _} = Auth.update_display_name(ctx.user, "New Name")

      assert [activity] = activities()
      assert activity["type"] == "Update"
      assert activity["object"]["type"] == "Person"
      assert activity["object"]["name"] == "New Name"
      assert inbox_urls() == [ctx.follower.inbox]
    end

    test "a new bio sends one too", ctx do
      {:ok, _} = Auth.update_bio(ctx.user, "Now with a bio.")

      assert [activity] = activities()
      assert activity["object"]["summary"] =~ "Now with a bio."
    end

    test "clearing the display name sends one as well", ctx do
      {:ok, user} = Auth.update_display_name(ctx.user, "Temporary")
      Repo.delete_all(DeliveryJob)

      {:ok, _} = Auth.update_display_name(user, "")

      assert [activity] = activities()
      refute Map.has_key?(activity["object"], "name")
    end
  end

  describe "a change followers cannot see sends nothing" do
    test "a signature is not in a Person document", ctx do
      {:ok, _} = Auth.update_signature(ctx.user, "-- sent from my BBS")
      assert activities() == []
    end

    test "narrowing dm_access sends nothing", ctx do
      {:ok, _} = Auth.update_dm_access(ctx.user, "nobody")
      assert activities() == []
    end

    test "notification preferences send nothing", ctx do
      {:ok, _} = Auth.update_notification_preferences(ctx.user, %{"mention" => false})
      assert activities() == []
    end

    test "saving the same display name again sends nothing", ctx do
      {:ok, user} = Auth.update_display_name(ctx.user, "Steady")
      Repo.delete_all(DeliveryJob)

      {:ok, _} = Auth.update_display_name(user, "Steady")
      assert activities() == []
    end

    test "a refused change sends nothing", ctx do
      admin = create_user(role: "admin")

      {:ok, _} =
        Auth.issue_sanction(admin, ctx.user, "silence",
          reason: "acceptance test",
          expires_at: DateTime.utc_now() |> DateTime.add(3600) |> DateTime.truncate(:second)
        )

      Repo.delete_all(DeliveryJob)

      assert {:error, _} = Auth.update_display_name(ctx.user, "Should not go out")
      assert activities() == []
    end
  end

  describe "a board is an actor too" do
    test "a new name sends Update(Group) to the board's followers", ctx do
      {:ok, _} = Content.update_board(ctx.board, %{name: "Renamed Board"})

      assert [activity] = activities()
      assert activity["object"]["type"] == "Group"
      assert activity["object"]["name"] == "Renamed Board"
      assert inbox_urls() == [ctx.board_follower.inbox]
    end

    test "a permission change no peer can see sends nothing", ctx do
      {:ok, _} = Content.update_board(ctx.board, %{min_role_to_post: "moderator"})
      assert activities() == []
    end
  end

  describe "a closed poll announces its final counts, once" do
    test "the sweep publishes Update(Question) and marks the poll", ctx do
      poll = closed_poll(ctx.user, ctx.board)

      assert Content.sweep_closed_polls() == 1

      assert [activity] = activities()
      assert activity["type"] == "Update"
      assert activity["object"]["type"] == "Question"
      assert activity["object"]["id"] == poll.ap_id
      assert Repo.get!(Content.Poll, poll.id).final_update_sent_at
    end

    test "a second sweep publishes nothing", ctx do
      _poll = closed_poll(ctx.user, ctx.board)
      assert Content.sweep_closed_polls() == 1
      Repo.delete_all(DeliveryJob)

      assert Content.sweep_closed_polls() == 0
      assert activities() == []
    end

    test "an open poll is left alone", ctx do
      {:ok, %{article: _article}} =
        create_article_with_poll(ctx.user, ctx.board,
          closes_at: DateTime.utc_now() |> DateTime.add(3600) |> DateTime.truncate(:second)
        )

      Repo.delete_all(DeliveryJob)

      assert Content.sweep_closed_polls() == 0
      assert activities() == []
    end

    test "a poll in a non-federated board is marked but never published", ctx do
      closed = create_board(ap_enabled: false)
      poll = closed_poll(ctx.user, closed)

      assert Content.sweep_closed_polls() == 1

      # Marked, so it is not retried every hour for ever — deciding not to
      # announce is a way of having handled it.
      assert Repo.get!(Content.Poll, poll.id).final_update_sent_at
      assert inbox_urls() == []
    end
  end

  # --- helpers ---

  defp activities do
    DeliveryJob |> Repo.all() |> Enum.map(&Jason.decode!(&1.activity_json)) |> Enum.uniq()
  end

  defp inbox_urls do
    DeliveryJob |> Repo.all() |> Enum.map(& &1.inbox_url) |> Enum.uniq()
  end

  defp follow(actor_uri, remote_actor) do
    {:ok, _} =
      Federation.create_follower(
        actor_uri,
        remote_actor,
        "#{remote_actor.ap_id}#follow-#{System.unique_integer([:positive])}"
      )
  end

  # `Poll.changeset/2` refuses a `closes_at` in the past, so a closed poll is
  # made by creating an open one and moving its clock — which is also what
  # happens in life.
  defp closed_poll(user, board) do
    soon = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.truncate(:second)
    {:ok, %{article: article}} = create_article_with_poll(user, board, closes_at: soon)
    poll = Content.get_poll_for_article(article.id)

    past = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.truncate(:second)
    from(p in Content.Poll, where: p.id == ^poll.id) |> Repo.update_all(set: [closes_at: past])

    Repo.delete_all(DeliveryJob)
    Repo.get!(Content.Poll, poll.id)
  end

  defp create_article_with_poll(user, board, opts) do
    Content.create_article(
      %{
        title: "Poll article",
        body: "Vote please",
        slug: "au-art-#{System.unique_integer([:positive])}",
        user_id: user.id
      },
      [board.id],
      poll: %{
        mode: "single",
        closes_at: Keyword.fetch!(opts, :closes_at),
        options: [%{text: "Yes", position: 0}, %{text: "No", position: 1}]
      }
    )
  end

  defp create_board(opts) do
    %Board{}
    |> Board.changeset(%{
      name: "Board",
      slug: "au-#{System.unique_integer([:positive])}",
      ap_enabled: Keyword.fetch!(opts, :ap_enabled)
    })
    |> Repo.insert!()
  end

  defp create_user(opts \\ []) do
    role_name = Keyword.get(opts, :role, "user")
    role = Repo.one!(from r in Setup.Role, where: r.name == ^role_name)

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => "au#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  defp create_remote_actor do
    n = System.unique_integer([:positive])

    %RemoteActor{}
    |> RemoteActor.changeset(%{
      ap_id: "https://remote.example/users/a#{n}",
      username: "a#{n}",
      domain: "remote.example",
      public_key_pem: "-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----",
      inbox: "https://remote.example/users/a#{n}/inbox",
      actor_type: "Person",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end
end
