defmodule Baudrate.ReleaseTest do
  use Baudrate.DataCase, async: false

  alias Baudrate.Content
  alias Baudrate.Content.{Board, Comment, Poll}
  alias Baudrate.Release
  alias Baudrate.Setup

  describe "migrate/0" do
    test "runs successfully when all migrations are already applied" do
      assert [{:ok, _, _}] = Release.migrate()
    end
  end

  describe "rollback/2" do
    test "returns ok tuple for a rollback to current version" do
      # Rolling back to version 0 would undo all migrations, so we just verify
      # the function accepts valid arguments and returns the expected shape.
      # We use a future version so no actual rollback occurs.
      assert {:ok, _, _} = Release.rollback(Baudrate.Repo, 99_999_999_999_999)
    end
  end

  describe "backfill_ap_ids/1 rewrites fragment ids (ADR 0050)" do
    setup do
      board =
        %Board{}
        |> Board.changeset(%{name: "B", slug: "rel-#{System.unique_integer([:positive])}"})
        |> Repo.insert!()

      Setup.seed_roles_and_permissions()
      user = create_user()

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "T",
            body: "B",
            slug: "rel-art-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          [board.id],
          poll: %{
            mode: "single",
            options: [%{text: "A", position: 0}, %{text: "B", position: 1}]
          }
        )

      {:ok, comment} =
        Content.create_comment(%{
          "body" => "c",
          "article_id" => article.id,
          "user_id" => user.id
        })

      poll = Content.get_poll_for_article(article.id)

      # Put both rows back into the pre-ADR-0050 shape the backfill has to heal.
      legacy_comment = "#{Baudrate.Federation.actor_uri(:user, user.username)}#note-#{comment.id}"
      legacy_poll = "#{article.ap_id}#poll"

      comment |> Ecto.Changeset.change(ap_id: legacy_comment) |> Repo.update!()
      poll |> Ecto.Changeset.change(ap_id: legacy_poll) |> Repo.update!()

      %{
        article: article,
        comment: comment,
        poll: poll,
        legacy_comment: legacy_comment,
        legacy_poll: legacy_poll
      }
    end

    test "a dry run writes nothing", ctx do
      Release.backfill_ap_ids(dry_run: true)

      assert Repo.get!(Comment, ctx.comment.id).ap_id == ctx.legacy_comment
      assert is_nil(Repo.get!(Comment, ctx.comment.id).legacy_ap_id)
      assert Repo.get!(Poll, ctx.poll.id).ap_id == ctx.legacy_poll
    end

    test "a real run mints the path and keeps the id peers know", ctx do
      Release.backfill_ap_ids()

      comment = Repo.get!(Comment, ctx.comment.id)
      poll = Repo.get!(Poll, ctx.poll.id)

      assert comment.ap_id == Baudrate.Federation.actor_uri(:comment, comment.id)
      assert comment.legacy_ap_id == ctx.legacy_comment
      assert poll.ap_id == Baudrate.Federation.actor_uri(:poll, poll.id)
      assert poll.legacy_ap_id == ctx.legacy_poll
    end

    test "re-running changes nothing, so an interrupted run resumes", ctx do
      Release.backfill_ap_ids()
      after_first = Repo.get!(Comment, ctx.comment.id)

      # The second pass must not record the *new* id as the legacy one, which
      # is what a naive "copy ap_id then overwrite" would do on every run.
      Release.backfill_ap_ids()
      after_second = Repo.get!(Comment, ctx.comment.id)

      assert after_second.ap_id == after_first.ap_id
      assert after_second.legacy_ap_id == ctx.legacy_comment
    end

    test "a remote comment is never rewritten", ctx do
      actor =
        %Baudrate.Federation.RemoteActor{}
        |> Baudrate.Federation.RemoteActor.changeset(%{
          ap_id: "https://remote.example/users/r#{System.unique_integer([:positive])}",
          username: "r#{System.unique_integer([:positive])}",
          domain: "remote.example",
          public_key_pem: "-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----",
          inbox: "https://remote.example/inbox",
          actor_type: "Person",
          fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.insert!()

      # A remote id can carry a fragment perfectly legitimately — it is that
      # host's to define, and rewriting it would break every reference to it.
      remote_ap_id = "https://remote.example/users/x/statuses/1#note-9"

      {:ok, remote_comment} =
        Content.create_remote_comment(%{
          body: "r",
          body_html: "<p>r</p>",
          ap_id: remote_ap_id,
          article_id: ctx.article.id,
          remote_actor_id: actor.id
        })

      Release.backfill_ap_ids()

      reloaded = Repo.get!(Comment, remote_comment.id)
      assert reloaded.ap_id == remote_ap_id
      assert is_nil(reloaded.legacy_ap_id)
    end
  end

  defp create_user do
    role = Repo.one!(from r in Setup.Role, where: r.name == "user")

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => "rel#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end
end
