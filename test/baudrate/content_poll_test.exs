defmodule Baudrate.ContentPollTest do
  use Baudrate.DataCase

  alias Baudrate.Content
  alias Baudrate.Content.Board
  alias Baudrate.Setup

  setup do
    Setup.seed_roles_and_permissions()
    :ok
  end

  defp create_user(role_name \\ "user") do
    role = Repo.one!(from(r in Setup.Role, where: r.name == ^role_name))

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => "poll_user_#{System.unique_integer([:positive])}",
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
      name: "Poll Board",
      slug: "poll-board-#{System.unique_integer([:positive])}"
    })
    |> Repo.insert!()
  end

  defp create_article_with_poll(user, board, poll_attrs \\ nil) do
    slug = "poll-art-#{System.unique_integer([:positive])}"

    poll_attrs =
      poll_attrs ||
        %{
          mode: "single",
          options: [
            %{text: "Option A", position: 0},
            %{text: "Option B", position: 1}
          ]
        }

    Content.create_article(
      %{title: "Poll Article", body: "With a poll", slug: slug, user_id: user.id},
      [board.id],
      poll: poll_attrs
    )
  end

  describe "create_article with poll" do
    test "creates article with poll and options" do
      user = create_user()
      board = create_board()

      assert {:ok, %{article: article, poll: poll}} = create_article_with_poll(user, board)
      assert poll.mode == "single"
      assert length(poll.options) == 2
      assert Enum.at(poll.options, 0).text == "Option A"
      assert Enum.at(poll.options, 1).text == "Option B"
      assert poll.article_id == article.id
    end

    test "creates article without poll when poll opt is omitted" do
      user = create_user()
      board = create_board()
      slug = "no-poll-#{System.unique_integer([:positive])}"

      {:ok, %{article: article}} =
        Content.create_article(
          %{title: "No Poll", body: "No poll here", slug: slug, user_id: user.id},
          [board.id]
        )

      assert Content.get_poll_for_article(article.id) == nil
    end

    test "creates article with multiple-choice poll" do
      user = create_user()
      board = create_board()

      poll_attrs = %{
        mode: "multiple",
        options: [
          %{text: "Red", position: 0},
          %{text: "Blue", position: 1},
          %{text: "Green", position: 2}
        ]
      }

      assert {:ok, %{poll: poll}} = create_article_with_poll(user, board, poll_attrs)
      assert poll.mode == "multiple"
      assert length(poll.options) == 3
    end
  end

  describe "get_article_by_slug! with poll" do
    test "preloads poll and options" do
      user = create_user()
      board = create_board()
      {:ok, %{article: article}} = create_article_with_poll(user, board)

      fetched = Content.get_article_by_slug!(article.slug)
      assert fetched.poll != nil
      assert fetched.poll.mode == "single"
      assert length(fetched.poll.options) == 2
    end
  end

  describe "get_poll_for_article/1" do
    test "returns poll with options" do
      user = create_user()
      board = create_board()
      {:ok, %{article: article}} = create_article_with_poll(user, board)

      poll = Content.get_poll_for_article(article.id)
      assert poll != nil
      assert length(poll.options) == 2
    end

    test "returns nil for article without poll" do
      user = create_user()
      board = create_board()
      slug = "no-poll-#{System.unique_integer([:positive])}"

      {:ok, %{article: article}} =
        Content.create_article(
          %{title: "No Poll", body: "Body", slug: slug, user_id: user.id},
          [board.id]
        )

      assert Content.get_poll_for_article(article.id) == nil
    end
  end

  describe "cast_vote/3" do
    test "records a single-choice vote and updates counts" do
      user = create_user()
      voter = create_user()
      board = create_board()
      {:ok, %{poll: poll}} = create_article_with_poll(user, board)

      option = List.first(poll.options)
      assert {:ok, updated_poll} = Content.cast_vote(poll, voter, [option.id])
      assert updated_poll.voters_count == 1

      voted_option = Enum.find(updated_poll.options, &(&1.id == option.id))
      assert voted_option.votes_count == 1
    end

    test "rejects multiple options for single-choice poll" do
      user = create_user()
      voter = create_user()
      board = create_board()
      {:ok, %{poll: poll}} = create_article_with_poll(user, board)

      option_ids = Enum.map(poll.options, & &1.id)
      assert {:error, :single_choice_requires_one} = Content.cast_vote(poll, voter, option_ids)
    end

    test "allows multiple options for multiple-choice poll" do
      user = create_user()
      voter = create_user()
      board = create_board()

      poll_attrs = %{
        mode: "multiple",
        options: [
          %{text: "A", position: 0},
          %{text: "B", position: 1},
          %{text: "C", position: 2}
        ]
      }

      {:ok, %{poll: poll}} = create_article_with_poll(user, board, poll_attrs)

      option_ids = Enum.map(Enum.take(poll.options, 2), & &1.id)
      assert {:ok, updated_poll} = Content.cast_vote(poll, voter, option_ids)
      assert updated_poll.voters_count == 1
    end

    test "vote change replaces previous votes" do
      user = create_user()
      voter = create_user()
      board = create_board()
      {:ok, %{poll: poll}} = create_article_with_poll(user, board)

      [opt_a, opt_b] = poll.options
      assert {:ok, _} = Content.cast_vote(poll, voter, [opt_a.id])

      # Change vote
      assert {:ok, updated_poll} = Content.cast_vote(poll, voter, [opt_b.id])
      assert updated_poll.voters_count == 1

      voted_a = Enum.find(updated_poll.options, &(&1.id == opt_a.id))
      voted_b = Enum.find(updated_poll.options, &(&1.id == opt_b.id))
      assert voted_a.votes_count == 0
      assert voted_b.votes_count == 1
    end

    test "rejects vote on closed poll" do
      user = create_user()
      voter = create_user()
      board = create_board()

      past = DateTime.utc_now() |> DateTime.add(1, :second)

      poll_attrs = %{
        mode: "single",
        closes_at: past,
        options: [
          %{text: "A", position: 0},
          %{text: "B", position: 1}
        ]
      }

      {:ok, %{poll: poll}} = create_article_with_poll(user, board, poll_attrs)

      # Wait for the poll to close
      Process.sleep(1100)

      option = List.first(poll.options)
      assert {:error, :poll_closed} = Content.cast_vote(poll, voter, [option.id])
    end

    test "rejects vote with invalid option ids" do
      user = create_user()
      voter = create_user()
      board = create_board()
      {:ok, %{poll: poll}} = create_article_with_poll(user, board)

      assert {:error, :invalid_options} = Content.cast_vote(poll, voter, [999_999])
    end

    test "rejects empty option selection" do
      user = create_user()
      voter = create_user()
      board = create_board()

      poll_attrs = %{
        mode: "multiple",
        options: [
          %{text: "A", position: 0},
          %{text: "B", position: 1}
        ]
      }

      {:ok, %{poll: poll}} = create_article_with_poll(user, board, poll_attrs)

      assert {:error, :no_options_selected} = Content.cast_vote(poll, voter, [])
    end
  end

  describe "get_user_poll_votes/2" do
    test "returns voted option ids" do
      user = create_user()
      voter = create_user()
      board = create_board()
      {:ok, %{poll: poll}} = create_article_with_poll(user, board)

      option = List.first(poll.options)
      Content.cast_vote(poll, voter, [option.id])

      votes = Content.get_user_poll_votes(poll.id, voter.id)
      assert votes == [option.id]
    end

    test "returns empty list when no votes" do
      user = create_user()
      board = create_board()
      {:ok, %{poll: poll}} = create_article_with_poll(user, board)

      assert Content.get_user_poll_votes(poll.id, user.id) == []
    end
  end
end
