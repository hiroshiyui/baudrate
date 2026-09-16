defmodule Baudrate.Setup.RulesTest do
  @moduledoc """
  Site rules as an ordered list of records (P1-D9), and what a report citing
  one is guaranteed.
  """
  use Baudrate.DataCase, async: false

  alias Baudrate.Moderation
  alias Baudrate.Repo
  alias Baudrate.Setup

  setup do
    Setup.seed_roles_and_permissions()
    :ok
  end

  defp rule(title) do
    {:ok, created} = Setup.create_rule(%{"title" => title})
    created
  end

  describe "the list" do
    test "numbers rules in the order they were added" do
      rule("Be civil")
      rule("Stay on topic")

      assert Enum.map(Setup.list_rules(), & &1.title) == ["Be civil", "Stay on topic"]
    end

    test "position is assigned here, never taken from the form" do
      # An admin typing a number is how two rules claim the same place.
      {:ok, first} = Setup.create_rule(%{"title" => "One", "position" => "99"})

      assert first.position == 1
    end

    test "trims the title and refuses an empty one" do
      {:ok, trimmed} = Setup.create_rule(%{"title" => "  Be civil  "})
      assert trimmed.title == "Be civil"

      assert {:error, changeset} = Setup.create_rule(%{"title" => "   "})
      assert errors_on(changeset)[:title]
    end
  end

  describe "reordering" do
    setup do
      %{a: rule("A"), b: rule("B"), c: rule("C")}
    end

    test "moving down swaps with the next rule", %{a: a} do
      {:ok, _} = Setup.move_rule(a, :down)

      assert Enum.map(Setup.list_rules(), & &1.title) == ["B", "A", "C"]
    end

    test "moving up swaps with the previous rule", %{c: c} do
      {:ok, _} = Setup.move_rule(c, :up)

      assert Enum.map(Setup.list_rules(), & &1.title) == ["A", "C", "B"]
    end

    test "the ends do not move", %{a: a, c: c} do
      assert {:error, :at_edge} = Setup.move_rule(a, :up)
      assert {:error, :at_edge} = Setup.move_rule(c, :down)
      assert Enum.map(Setup.list_rules(), & &1.title) == ["A", "B", "C"]
    end

    test "no two rules ever share a position", %{a: a, b: b} do
      {:ok, _} = Setup.move_rule(a, :down)
      {:ok, _} = Setup.move_rule(Repo.reload(b), :down)

      positions = Setup.list_rules() |> Enum.map(& &1.position)
      assert positions == Enum.uniq(positions)
    end
  end

  describe "retiring" do
    test "takes the rule off the published list but does not delete it" do
      keep = rule("Keep")
      gone = rule("Gone")

      {:ok, retired} = Setup.retire_rule(gone)

      assert Enum.map(Setup.list_rules(), & &1.title) == ["Keep"]
      assert Repo.get(Setup.Rule, retired.id)
      assert Enum.map(Setup.list_retired_rules(), & &1.title) == ["Gone"]
      assert keep
    end

    test "a report that cited it still names which rule" do
      # The whole reason rules are retired rather than deleted: a hard delete
      # would quietly empty the citation on every past report.
      broken = rule("No spam")
      reporter = member()
      article = article(member())

      {:ok, report} =
        Moderation.create_report(%{
          reporter_id: reporter.id,
          article_id: article.id,
          category: "rule_violation",
          rule_id: broken.id,
          reason: "This breaks rule 1."
        })

      {:ok, _} = Setup.retire_rule(broken)

      assert %{rule: %{title: "No spam"}} = Moderation.get_report!(report.id)
    end

    test "refuses to retire twice, so the original date stands" do
      r = rule("Once")
      {:ok, first} = Setup.retire_rule(r)

      assert {:error, :already_retired} = Setup.retire_rule(Repo.reload(first))
      assert Repo.reload(first).retired_at == first.retired_at
    end

    test "restoring puts it back at the end, never reusing a number" do
      a = rule("A")
      _b = rule("B")

      {:ok, retired} = Setup.retire_rule(a)
      {:ok, restored} = Setup.restore_rule(Repo.reload(retired))

      assert Enum.map(Setup.list_rules(), & &1.title) == ["B", "A"]
      assert restored.position == 3
    end
  end

  describe "citing a rule on a report" do
    test "is optional, so a reporter who cannot find the number can still report" do
      rule("No spam")
      reporter = member()
      article = article(member())

      assert {:ok, report} =
               Moderation.create_report(%{
                 reporter_id: reporter.id,
                 article_id: article.id,
                 category: "rule_violation",
                 reason: "Something is wrong here."
               })

      assert report.rule_id == nil
    end

    test "a rule id that names nothing is refused rather than stored" do
      reporter = member()
      article = article(member())

      assert {:error, changeset} =
               Moderation.create_report(%{
                 reporter_id: reporter.id,
                 article_id: article.id,
                 category: "rule_violation",
                 rule_id: 999_999,
                 reason: "Pointing at a rule that does not exist."
               })

      assert errors_on(changeset)[:rule_id]
    end
  end

  describe "the footer" do
    test "counts rules as published only once one exists" do
      refute :rules in Setup.published_policies()

      rule("Be civil")

      assert :rules in Setup.published_policies()
    end

    test "stops counting them when the last one is retired" do
      only = rule("Be civil")
      {:ok, _} = Setup.retire_rule(only)

      refute :rules in Setup.published_policies()
    end
  end

  defp member do
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

    Repo.update_all(from(u in Setup.User, where: u.id == ^user.id), set: [status: "active"])
    Repo.reload(user)
  end

  defp article(user) do
    n = System.unique_integer([:positive])

    board =
      %Baudrate.Content.Board{}
      |> Baudrate.Content.Board.changeset(%{name: "Board", slug: "board-#{n}"})
      |> Repo.insert!()

    {:ok, %{article: article}} =
      Baudrate.Content.create_article(
        %{"title" => "A post", "body" => "Words.", "slug" => "post-#{n}", "user_id" => user.id},
        [board.id]
      )

    article
  end
end
