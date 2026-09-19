defmodule Baudrate.Content.PollAnonymityTest do
  @moduledoc """
  Acceptance gate for [ADR 0048](../../../doc/adr/0048-a-poll-records-who-voted-and-nothing-reads-it-back.md).

  `poll_votes` carries a `user_id` and a `remote_actor_id`, because a poll has
  to deduplicate, let someone change their mind, and show a member their own
  choice. The promise is not that nobody knows — it is that nothing reads it
  back. So this checks the reading, not the writing: every surface that renders
  a poll carries counts, and nothing that names a voter other than the viewer.

  A new poll surface belongs here.
  """

  use Baudrate.DataCase, async: false

  alias Baudrate.Content
  alias Baudrate.Content.Board
  alias Baudrate.Federation.{ObjectBuilder, RemoteActor}
  alias Baudrate.Setup

  setup do
    Setup.seed_roles_and_permissions()

    board = create_board()
    author = create_user()
    alice = create_user()
    bob = create_user()

    {:ok, %{article: article}} = create_article_with_poll(author, board)
    poll = Content.get_poll_for_article(article.id) |> Content.preload_poll_options()
    [option_a, option_b] = Enum.sort_by(poll.options, & &1.position)

    {:ok, _} = Content.cast_vote(poll, alice, [option_a.id])
    {:ok, poll} = Content.cast_vote(poll, bob, [option_b.id])

    remote = create_remote_actor()

    {:ok, _} =
      Content.create_remote_poll_vote(%{
        poll_id: poll.id,
        poll_option_id: option_a.id,
        remote_actor_id: remote.id
      })

    {:ok, poll} = Content.recalc_poll_counts(poll.id)

    %{
      article: article,
      poll: Content.preload_poll_options(poll),
      alice: alice,
      bob: bob,
      remote: remote,
      option_a: option_a,
      option_b: option_b
    }
  end

  describe "the context reads a voter only on that voter's behalf" do
    test "each member sees their own choice and nobody else's", ctx do
      assert Content.get_user_poll_votes(ctx.poll.id, ctx.alice.id) == [ctx.option_a.id]
      assert Content.get_user_poll_votes(ctx.poll.id, ctx.bob.id) == [ctx.option_b.id]
    end

    test "there is no function that lists a poll's voters", _ctx do
      # ADR 0048 decision 1: no `list_voters`, for anyone, including admins.
      # `get_user_poll_votes/2` takes the asker's id, which is what makes it
      # impossible to call without already knowing whose votes you want.
      exported = Baudrate.Content.Polls.__info__(:functions)

      for {name, _arity} <- exported do
        refute name |> Atom.to_string() |> String.contains?("voters"),
               "Content.Polls exports #{name}, which reads like a voter listing. " <>
                 "ADR 0048 decision 1: there is one read path and it is scoped " <>
                 "to the asker."
      end

      assert {:get_user_poll_votes, 2} in exported
    end
  end

  describe "the counts are what every surface has in hand" do
    test "the poll carries totals, not a voter list", ctx do
      assert ctx.poll.voters_count == 3

      by_id = Map.new(ctx.poll.options, &{&1.id, &1.votes_count})
      assert by_id[ctx.option_a.id] == 2
      assert by_id[ctx.option_b.id] == 1

      refute Map.has_key?(ctx.poll, :voters)
    end
  end

  describe "federation publishes counts and no collection" do
    test "the Question attachment has totalItems and no items", ctx do
      article =
        ctx.article
        |> Repo.preload([:user, :boards, :article_images, :remote_actor, :link_preview])

      object = ObjectBuilder.article_object(article)

      question =
        object
        |> Map.get("attachment", [])
        |> Enum.find(&(&1["type"] == "Question"))

      assert question, "the article object carries no Question attachment"
      assert question["votersCount"] == 3

      options = question["oneOf"] || question["anyOf"]
      assert length(options) == 2

      for option <- options do
        replies = option["replies"]
        assert replies["type"] == "Collection"
        assert is_integer(replies["totalItems"])

        refute Map.has_key?(replies, "items"),
               "ADR 0048 decision 3: a poll option's replies Collection is the " <>
                 "natural place to list who voted, and is left empty deliberately."

        refute Map.has_key?(replies, "orderedItems")
      end
    end

    test "no voter's name or actor URI appears anywhere in the object", ctx do
      article =
        ctx.article
        |> Repo.preload([:user, :boards, :article_images, :remote_actor, :link_preview])

      json = ObjectBuilder.article_object(article) |> Jason.encode!()

      for {label, needle} <- [
            {"alice's username", ctx.alice.username},
            {"bob's username", ctx.bob.username},
            {"the remote voter's ap_id", ctx.remote.ap_id},
            {"the remote voter's username", ctx.remote.username}
          ] do
        refute String.contains?(json, needle),
               "#{label} (#{needle}) is in the published article object"
      end
    end
  end

  defp create_user do
    role = Repo.one!(from(r in Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => "pollanon#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.update_all(from(u in Setup.User, where: u.id == ^user.id), set: [status: "active"])
    Repo.get!(Setup.User, user.id) |> Repo.preload(:role)
  end

  defp create_remote_actor do
    uid = System.unique_integer([:positive])

    %RemoteActor{}
    |> RemoteActor.changeset(%{
      ap_id: "https://remote.example/users/pollvoter#{uid}",
      username: "pollvoter#{uid}",
      domain: "remote.example",
      inbox: "https://remote.example/users/pollvoter#{uid}/inbox",
      public_key_pem: "-----BEGIN PUBLIC KEY-----\nx\n-----END PUBLIC KEY-----",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  defp create_board do
    %Board{}
    |> Board.changeset(%{
      name: "Poll Anonymity Board",
      slug: "poll-anon-#{System.unique_integer([:positive])}"
    })
    |> Repo.insert!()
  end

  defp create_article_with_poll(user, board) do
    Content.create_article(
      %{
        title: "Poll Article",
        body: "With a poll",
        slug: "poll-anon-art-#{System.unique_integer([:positive])}",
        user_id: user.id
      },
      [board.id],
      poll: %{
        mode: "single",
        options: [
          %{text: "Option A", position: 0},
          %{text: "Option B", position: 1}
        ]
      }
    )
  end
end
