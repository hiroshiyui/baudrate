defmodule Baudrate.Auth.SanctionsGateTest do
  @moduledoc """
  The completeness of the interaction gate is tested, not remembered (ADR 0029).

  Two things are checked here:

    1. **The guard.** `AccountMigration.ensure_not_moved/1` is the narrow,
       moved-account-only predicate the gate replaced. A new posting path that
       calls it would enforce the old rule and let a silenced account through,
       so it may appear only in the files listed below.
    2. **The paths.** Every way an account can create content or interact
       refuses a silenced account at the context boundary.
  """

  use Baudrate.DataCase, async: false

  import Ecto.Query

  alias Baudrate.Auth
  alias Baudrate.Auth.Sanction
  alias Baudrate.Content
  alias Baudrate.Federation
  alias Baudrate.Messaging
  alias Baudrate.Repo
  alias Baudrate.Setup

  # `ensure_not_moved/1` belongs to the *target* side of a move — "this
  # account is followed at its new address" — which is a different rule from
  # "this account may act". Only these two files may mention it.
  @ensure_not_moved_allowed [
    # the definition
    "lib/baudrate/account_migration.ex",
    # the followed account in `create_local_follow/2`
    "lib/baudrate/federation/follows.ex"
  ]

  setup do
    Setup.seed_roles_and_permissions()

    %{user: user("silenced"), other: user("other")}
  end

  describe "the guard" do
    test "ensure_not_moved/1 is not called as an interaction gate anywhere" do
      offenders =
        "lib/**/*.ex"
        |> Path.wildcard()
        |> Enum.reject(&(&1 in @ensure_not_moved_allowed))
        |> Enum.filter(&(ensure_not_moved_calls(&1) > 0))

      assert offenders == [],
             """
             These files call AccountMigration.ensure_not_moved/1, which only
             knows about moved accounts and would let a silenced or suspended
             account through. Call Auth.ensure_can_interact/1 instead (ADR 0029):

             #{Enum.map_join(offenders, "\n", &"  - #{&1}")}
             """
    end

    test "the allow-listed files still call it, so the guard means something" do
      # Otherwise the guard above passes because the call moved somewhere the
      # walk cannot see, not because it was replaced.
      for path <- @ensure_not_moved_allowed do
        assert File.exists?(path), "#{path} is gone; update the allow-list"

        assert ensure_not_moved_calls(path) > 0,
               "#{path} no longer calls ensure_not_moved/1; drop it from the allow-list"
      end
    end
  end

  describe "ensure_can_interact/1" do
    test "allows an ordinary account", %{user: user} do
      assert Auth.ensure_can_interact(user) == :ok
      assert Auth.ensure_can_interact(user.id) == :ok
      assert Auth.can_interact?(user)
    end

    test "is :ok for nil and for an unknown id" do
      assert Auth.ensure_can_interact(nil) == :ok
      assert Auth.ensure_can_interact(-1) == :ok
    end

    test "refuses a silenced account", %{user: user} do
      silence(user)
      assert Auth.ensure_can_interact(user) == {:error, :account_silenced}
      refute Auth.can_interact?(user)
    end

    test "refuses a suspended account", %{user: user} do
      suspend(user)
      assert Auth.ensure_can_interact(user) == {:error, :account_suspended}
    end

    test "refuses a banned account", %{user: user} do
      Repo.update_all(from(u in Setup.User, where: u.id == ^user.id), set: [status: "banned"])
      assert Auth.ensure_can_interact(user) == {:error, :banned}
    end

    test "refuses a moved account with the shape callers already handle", %{user: user} do
      Repo.update_all(
        from(u in Setup.User, where: u.id == ^user.id),
        set: [moved_to: "https://remote.example/users/elsewhere"]
      )

      assert Auth.ensure_can_interact(user) == {:error, :account_moved}
    end

    test "a warning restricts nothing", %{user: user} do
      insert_sanction(user, "warn", nil)
      assert Auth.ensure_can_interact(user) == :ok
    end

    test "an expired sanction restricts nothing — no sweep is needed", %{user: user} do
      insert_sanction(user, "silence", minutes_from_now(-1))
      assert Auth.ensure_can_interact(user) == :ok
    end

    test "a lifted sanction restricts nothing", %{user: user} do
      sanction = insert_sanction(user, "silence", nil)

      sanction
      |> Sanction.lift_changeset(%{lifted_at: DateTime.utc_now() |> DateTime.truncate(:second)})
      |> Repo.update!()

      assert Auth.ensure_can_interact(user) == :ok
    end

    test "reports the strongest reason first", %{user: user} do
      silence(user)
      suspend(user)
      assert Auth.ensure_can_interact(user) == {:error, :account_suspended}
    end
  end

  describe "active sanctions" do
    test "stack forward: the end shown is the furthest away", %{user: user} do
      insert_sanction(user, "silence", minutes_from_now(60))
      insert_sanction(user, "silence", minutes_from_now(10))

      assert %Sanction{} = furthest = Auth.active_sanction(user, "silence")
      assert DateTime.diff(furthest.expires_at, DateTime.utc_now()) > 30 * 60
    end

    test "an indefinite sanction outranks a dated one", %{user: user} do
      insert_sanction(user, "silence", minutes_from_now(60))
      insert_sanction(user, "silence", nil)

      assert %Sanction{expires_at: nil} = Auth.active_sanction(user, "silence")
    end

    test "list_sanctions/1 keeps lifted and expired rows as history", %{user: user} do
      insert_sanction(user, "warn", nil)
      insert_sanction(user, "silence", minutes_from_now(-1))

      assert length(Auth.list_sanctions(user)) == 2
      assert Auth.active_sanctions(user) == []
    end
  end

  describe "every interaction path refuses a silenced account" do
    setup [:with_board]

    test "creating an article", %{user: user, board: board} do
      silence(user)

      assert {:error, :account, :account_silenced, _} =
               Content.create_article(
                 %{
                   title: "Nope",
                   body: "Nope",
                   slug: "gate-nope-#{System.unique_integer([:positive])}",
                   user_id: user.id
                 },
                 [board.id]
               )
    end

    test "editing an article", %{user: user, board: board} do
      article = article_by(user, board)
      silence(user)

      assert Content.update_article(article, %{title: "Edited"}, user) ==
               {:error, :account_silenced}
    end

    test "commenting", %{user: user, board: board, other: other} do
      article = article_by(other, board)
      silence(user)

      assert Content.create_comment(%{
               "user_id" => user.id,
               "article_id" => article.id,
               "body" => "hi"
             }) ==
               {:error, :account_silenced}
    end

    test "liking an article", %{user: user, board: board, other: other} do
      article = article_by(other, board)
      silence(user)

      assert Content.toggle_article_like(user.id, article.id) == {:error, :account_silenced}
    end

    test "boosting an article", %{user: user, board: board, other: other} do
      article = article_by(other, board)
      silence(user)

      assert Content.toggle_article_boost(user.id, article.id) == {:error, :account_silenced}
    end

    test "undoing an earlier like stays allowed", %{user: user, board: board, other: other} do
      article = article_by(other, board)
      assert {:ok, _like} = Content.toggle_article_like(user.id, article.id)

      silence(user)

      assert Content.toggle_article_like(user.id, article.id) == {:ok, :removed}
    end

    test "voting in a poll", %{user: user, board: board, other: other} do
      article =
        article_by(other, board,
          poll: %{
            mode: "single",
            options: [%{text: "Yes", position: 0}, %{text: "No", position: 1}]
          }
        )

      %{poll: poll} = Repo.preload(article, poll: :options)
      [option | _] = poll.options
      silence(user)

      assert Content.cast_vote(poll, user, [option.id]) == {:error, :account_silenced}
    end

    test "following another member", %{user: user, other: other} do
      silence(user)
      assert Federation.create_local_follow(user, other) == {:error, :account_silenced}
    end

    test "sending a direct message", %{user: user, other: other} do
      {:ok, conversation} = Messaging.find_or_create_conversation(user, other)
      silence(user)

      assert Messaging.create_message(conversation, user, %{body: "hello"}) ==
               {:error, :not_allowed}
    end

    test "generating an invite code", %{user: user} do
      silence(user)
      assert Auth.can_generate_invite?(user) == {:error, :account_silenced}
    end

    test "changing the bio, display name and profile fields", %{user: user} do
      silence(user)

      assert Auth.update_bio(user, "a billboard") == {:error, :account_silenced}
      assert Auth.update_display_name(user, "Still Here") == {:error, :account_silenced}

      assert Auth.update_profile_fields(user, [%{"name" => "site", "value" => "x"}]) ==
               {:error, :account_silenced}
    end

    test "reporting abuse and account settings stay open", %{
      user: user,
      board: board,
      other: other
    } do
      article = article_by(other, board)
      silence(user)

      # A silenced member must still be able to report abuse.
      assert {:ok, _report} =
               Baudrate.Moderation.create_report(%{
                 "reporter_id" => user.id,
                 "article_id" => article.id,
                 "reason" => "spam",
                 "category" => "spam"
               })

      # Narrowing who may DM you makes the account safer, not louder.
      assert {:ok, _user} = Auth.update_dm_access(user, "nobody")
    end

    test "can_create_content? is false", %{user: user} do
      silence(user)
      refute Auth.can_create_content?(Repo.preload(user, :role))
    end
  end

  # --- helpers ---

  defp with_board(%{user: _user} = context) do
    {:ok, board} =
      Content.create_board(%{
        name: "Gate #{System.unique_integer([:positive])}",
        slug: "gate-#{System.unique_integer([:positive])}",
        description: "gate test"
      })

    Map.put(context, :board, board)
  end

  defp user(prefix) do
    role = Repo.one!(from(r in Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => "#{prefix}_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.update_all(from(u in Setup.User, where: u.id == ^user.id), set: [status: "active"])
    Repo.preload(%{user | status: "active"}, :role)
  end

  defp article_by(author, board, opts \\ []) do
    uid = System.unique_integer([:positive])

    {:ok, %{article: article}} =
      Content.create_article(
        %{title: "Post #{uid}", body: "body", slug: "gate-#{uid}", user_id: author.id},
        [board.id],
        opts
      )

    article
  end

  defp silence(user), do: insert_sanction(user, "silence", nil)
  defp suspend(user), do: insert_sanction(user, "suspend", minutes_from_now(60))

  defp insert_sanction(user, kind, expires_at) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Straight to the row: an already-expired sanction is history, and
    # `issue_changeset/2` rightly refuses to create one.
    Repo.insert!(%Sanction{
      user_id: user.id,
      kind: kind,
      reason: "test",
      issued_at: now,
      expires_at: expires_at,
      inserted_at: now,
      updated_at: now
    })
  end

  # Counts real calls, so a mention in a @moduledoc or a comment does not
  # trip the guard.
  defp ensure_not_moved_calls(path) do
    {_ast, count} =
      path
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk(0, fn
        {{:., _, [_module, :ensure_not_moved]}, _, _args} = node, acc -> {node, acc + 1}
        {:ensure_not_moved, _, args} = node, acc when is_list(args) -> {node, acc + 1}
        node, acc -> {node, acc}
      end)

    count
  end

  defp minutes_from_now(minutes) do
    DateTime.utc_now() |> DateTime.add(minutes * 60, :second) |> DateTime.truncate(:second)
  end
end
