defmodule Baudrate.Auth.TermsGateTest do
  @moduledoc """
  The pause that published terms put on posting (P1-D8), and everything it
  must **not** stop.

  This is the acceptance gate for the re-acceptance half of 1E. The check lives
  inside `Auth.ensure_can_interact/1`, which is what makes it apply to every
  way of posting at once — so the tests that matter most here are the ones
  proving what stays open: reading, undoing, reporting, and bot posting.
  """
  use Baudrate.DataCase, async: false

  import Ecto.Query

  alias Baudrate.Auth
  alias Baudrate.Content
  alias Baudrate.Content.Board
  alias Baudrate.Moderation
  alias Baudrate.Repo
  alias Baudrate.Setup

  setup do
    Setup.seed_roles_and_permissions()
    Setup.update_eua("Be excellent to each other.")

    board =
      %Board{}
      |> Board.changeset(%{name: "Board", slug: "board-#{System.unique_integer([:positive])}"})
      |> Repo.insert!()

    %{board: board, member: member(), other: member()}
  end

  defp member(attrs \\ %{}) do
    role = Repo.one!(from(r in Setup.Role, where: r.name == "user"))
    n = System.unique_integer([:positive])

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => "member#{n}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.update_all(from(u in Setup.User, where: u.id == ^user.id),
      set: Enum.to_list(Map.merge(%{status: "active"}, attrs))
    )

    Repo.reload(user)
  end

  defp post(user, board, title \\ "A post") do
    Content.create_article(
      %{
        "title" => title,
        "body" => "Some words.",
        "slug" => "post-#{System.unique_integer([:positive])}",
        "user_id" => user.id
      },
      [board.id]
    )
  end

  describe "before anything is published" do
    test "nobody is asked to accept", %{member: member} do
      assert Auth.ensure_can_interact(member) == :ok
      refute Auth.terms_pending?(member)
    end

    test "saving the terms without publishing asks nobody", %{member: member} do
      Setup.update_eua("Be excellent to each other. (typo fixed)")

      assert Auth.ensure_can_interact(member) == :ok
    end
  end

  describe "after publishing a new version" do
    setup %{member: member, board: board, other: other} do
      # Seeded before publishing: afterwards `other` is paused too.
      {:ok, %{article: existing}} = post(other, board, "Still readable")
      {:ok, version} = Setup.publish_terms_version()

      %{member: Repo.reload(member), version: version, existing: existing}
    end

    test "posting is refused", %{member: member, board: board} do
      assert Auth.ensure_can_interact(member) == {:error, :terms_not_accepted}
      assert {:error, :account, :terms_not_accepted, _} = post(member, board)
    end

    test "commenting is refused", %{member: member, existing: article} do
      assert {:error, :terms_not_accepted} =
               Content.create_comment(%{
                 "body" => "A reply.",
                 "article_id" => article.id,
                 "user_id" => member.id
               })
    end

    test "reading is not affected", %{member: member, board: board, existing: article} do
      # `other` accepted nothing either, and their existing post stays visible.
      assert "Still readable" in Enum.map(Content.list_articles_for_board(board), & &1.title)
      assert Content.get_article_by_slug!(article.slug)
      assert Auth.terms_pending?(member)
    end

    test "accepting clears it", %{member: member, board: board} do
      {:ok, accepted} = Auth.accept_current_terms(member)

      refute Auth.terms_pending?(accepted)
      assert Auth.ensure_can_interact(accepted) == :ok
      assert {:ok, %{article: _}} = post(accepted, board)
    end

    test "accepting records the version that was actually published", %{
      member: member,
      version: version
    } do
      {:ok, accepted} = Auth.accept_current_terms(member)

      assert accepted.terms_version == version
      assert %DateTime{} = accepted.terms_accepted_at
    end

    test "publishing again asks the same member once more", %{member: member} do
      {:ok, accepted} = Auth.accept_current_terms(member)
      assert Auth.ensure_can_interact(accepted) == :ok

      {:ok, _} = Setup.publish_terms_version()

      assert Auth.ensure_can_interact(Repo.reload(accepted)) == {:error, :terms_not_accepted}
    end
  end

  describe "what the pause must never stop" do
    setup %{board: board, member: member, other: other} do
      # Post before publishing, so there is something to undo and report.
      {:ok, %{article: mine}} = post(member, board, "Mine")
      {:ok, %{article: theirs}} = post(other, board, "Theirs")
      {:ok, %{article: fresh}} = post(other, board, "Fresh")
      {:ok, _} = Content.toggle_article_like(member.id, theirs.id)
      {:ok, _} = Setup.publish_terms_version()

      %{member: Repo.reload(member), mine: mine, theirs: theirs, fresh: fresh}
    end

    test "a bot keeps posting", %{board: board} do
      # A bot user cannot sign in, so it can never accept. Bot articles go
      # through `create_article/3` and therefore this same gate: without the
      # exemption, publishing terms would silently stop every RSS feed.
      bot = member(%{is_bot: true})

      assert Auth.ensure_can_interact(bot) == :ok
      refute Auth.terms_pending?(bot)

      assert {:ok, %{article: _}} =
               Content.create_article(
                 %{
                   "title" => "From a feed",
                   "body" => "Words.",
                   "slug" => "timeline-#{System.unique_integer([:positive])}",
                   "user_id" => bot.id
                 },
                 [board.id],
                 trusted: true
               )
    end

    test "undoing an earlier like still works", %{member: member, theirs: theirs} do
      assert {:ok, _} = Content.toggle_article_like(member.id, theirs.id)
    end

    test "a new like is refused", %{member: member, fresh: fresh} do
      assert {:error, :terms_not_accepted} = Content.toggle_article_like(member.id, fresh.id)
    end

    test "deleting your own post still works", %{member: member, mine: mine} do
      assert {:ok, _} = Content.soft_delete_article(mine, deleted_by: member.id)
    end

    test "reporting abuse still works", %{member: member, theirs: theirs} do
      # A member who cannot report is a member who cannot ask for help. The
      # terms are not a reason to take that away.
      assert {:ok, _report} =
               Moderation.create_report(%{
                 reporter_id: member.id,
                 article_id: theirs.id,
                 category: "harassment",
                 reason: "Please look at this."
               })
    end

    test "a guest is unaffected" do
      assert Auth.ensure_can_interact(nil) == :ok
      refute Auth.terms_pending?(nil)
    end
  end

  describe "alongside a sanction" do
    test "the silence is named, because that is what has to be lifted", %{member: member} do
      moderator = Repo.one!(from(u in Setup.User, where: u.id == ^member.id))
      admin_role = Repo.one!(from(r in Setup.Role, where: r.name == "admin"))

      staff = member()

      Repo.update_all(from(u in Setup.User, where: u.id == ^staff.id),
        set: [role_id: admin_role.id]
      )

      {:ok, _} = Auth.issue_sanction(Repo.reload(staff), moderator, "silence")
      {:ok, _} = Setup.publish_terms_version()

      # Both stand. The member is told about the one they cannot clear alone.
      assert Auth.ensure_can_interact(Repo.reload(member)) == {:error, :account_silenced}
    end
  end
end
