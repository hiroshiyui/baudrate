defmodule Baudrate.Federation.PublisherPollTest do
  use Baudrate.DataCase, async: false

  alias Baudrate.Content
  alias Baudrate.Content.Board
  alias Baudrate.Federation
  alias Baudrate.Federation.{KeyStore, Publisher}

  setup do
    Baudrate.Setup.seed_roles_and_permissions()
    :ok
  end

  defp create_user do
    role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %Baudrate.Setup.User{}
      |> Baudrate.Setup.User.registration_changeset(%{
        "username" => "pub_poll_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    {:ok, user} = KeyStore.ensure_user_keypair(user)
    Repo.preload(user, :role)
  end

  defp create_board do
    slug = "pub-poll-#{System.unique_integer([:positive])}"

    board =
      %Board{}
      |> Board.changeset(%{name: "Poll Publisher Board", slug: slug})
      |> Repo.insert!()

    {:ok, board} = KeyStore.ensure_board_keypair(board)
    board
  end

  defp create_article_with_poll(user, board) do
    slug = "pub-poll-art-#{System.unique_integer([:positive])}"

    {:ok, %{article: article}} =
      Content.create_article(
        %{title: "Poll Article", body: "With poll", slug: slug, user_id: user.id},
        [board.id],
        poll: %{
          mode: "single",
          options: [
            %{text: "Yes", position: 0},
            %{text: "No", position: 1}
          ]
        }
      )

    Process.sleep(50)
    Repo.preload(article, [:boards, :user, poll: :options])
  end

  describe "article_object/1 with poll" do
    test "includes poll attachment with oneOf for single-choice" do
      user = create_user()
      board = create_board()
      article = create_article_with_poll(user, board)

      object = Federation.article_object(article)

      assert is_list(object["attachment"])
      question = List.first(object["attachment"])
      assert question["type"] == "Question"
      assert is_list(question["oneOf"])
      assert length(question["oneOf"]) == 2

      first_option = List.first(question["oneOf"])
      assert first_option["type"] == "Note"
      assert first_option["name"] == "Yes"
      assert first_option["replies"]["totalItems"] == 0
      assert question["votersCount"] == 0
    end

    test "includes anyOf for multiple-choice poll" do
      user = create_user()
      board = create_board()
      slug = "multi-poll-#{System.unique_integer([:positive])}"

      {:ok, %{article: article}} =
        Content.create_article(
          %{title: "Multi Poll", body: "Body", slug: slug, user_id: user.id},
          [board.id],
          poll: %{
            mode: "multiple",
            options: [
              %{text: "A", position: 0},
              %{text: "B", position: 1},
              %{text: "C", position: 2}
            ]
          }
        )

      Process.sleep(50)
      article = Repo.preload(article, [:boards, :user, poll: :options])
      object = Federation.article_object(article)

      question = List.first(object["attachment"])
      assert is_list(question["anyOf"])
      assert length(question["anyOf"]) == 3
      refute Map.has_key?(question, "oneOf")
    end

    test "includes endTime when poll has closes_at" do
      user = create_user()
      board = create_board()
      slug = "timed-poll-#{System.unique_integer([:positive])}"
      future = DateTime.utc_now() |> DateTime.add(86400, :second) |> DateTime.truncate(:second)

      {:ok, %{article: article}} =
        Content.create_article(
          %{title: "Timed Poll", body: "Body", slug: slug, user_id: user.id},
          [board.id],
          poll: %{
            mode: "single",
            closes_at: future,
            options: [
              %{text: "X", position: 0},
              %{text: "Y", position: 1}
            ]
          }
        )

      Process.sleep(50)
      article = Repo.preload(article, [:boards, :user, poll: :options])
      object = Federation.article_object(article)

      question = List.first(object["attachment"])
      assert question["endTime"] == DateTime.to_iso8601(future)
    end

    test "no attachment when article has no poll" do
      user = create_user()
      board = create_board()
      slug = "no-poll-pub-#{System.unique_integer([:positive])}"

      {:ok, %{article: article}} =
        Content.create_article(
          %{title: "No Poll", body: "Body", slug: slug, user_id: user.id},
          [board.id]
        )

      Process.sleep(50)
      article = Repo.preload(article, [:boards, :user, poll: :options])
      object = Federation.article_object(article)

      refute Map.has_key?(object, "attachment")
    end
  end

  describe "build_create_vote/3" do
    test "builds vote activities for selected options" do
      user = create_user()
      voter = create_user()
      board = create_board()
      article = create_article_with_poll(user, board)

      voted_options = article.poll.options

      activities = Publisher.build_create_vote(voter, article, voted_options)
      assert length(activities) == 2

      {activity, actor_uri} = List.first(activities)
      assert activity["type"] == "Create"
      assert activity["actor"] == actor_uri
      assert activity["object"]["type"] == "Note"
      assert activity["object"]["name"] in ["Yes", "No"]
      assert is_binary(activity["object"]["inReplyTo"])
    end
  end
end
