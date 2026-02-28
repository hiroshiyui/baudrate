defmodule Baudrate.Content.PollTest do
  use Baudrate.DataCase

  alias Baudrate.Content.{Poll, PollOption}

  describe "Poll.changeset/2" do
    test "valid with mode single and 2 options" do
      changeset =
        Poll.changeset(%Poll{}, %{
          mode: "single",
          article_id: 1,
          options: [
            %{text: "Option A", position: 0},
            %{text: "Option B", position: 1}
          ]
        })

      assert changeset.valid?
    end

    test "valid with mode multiple and 4 options" do
      changeset =
        Poll.changeset(%Poll{}, %{
          mode: "multiple",
          article_id: 1,
          options: [
            %{text: "A", position: 0},
            %{text: "B", position: 1},
            %{text: "C", position: 2},
            %{text: "D", position: 3}
          ]
        })

      assert changeset.valid?
    end

    test "rejects invalid mode" do
      changeset =
        Poll.changeset(%Poll{}, %{
          mode: "ranked",
          article_id: 1,
          options: [
            %{text: "A", position: 0},
            %{text: "B", position: 1}
          ]
        })

      assert %{mode: _} = errors_on(changeset)
    end

    test "rejects fewer than 2 options" do
      changeset =
        Poll.changeset(%Poll{}, %{
          mode: "single",
          article_id: 1,
          options: [
            %{text: "Only one", position: 0}
          ]
        })

      assert %{options: ["must have at least 2 options"]} = errors_on(changeset)
    end

    test "rejects more than 4 options" do
      changeset =
        Poll.changeset(%Poll{}, %{
          mode: "single",
          article_id: 1,
          options: [
            %{text: "A", position: 0},
            %{text: "B", position: 1},
            %{text: "C", position: 2},
            %{text: "D", position: 3},
            %{text: "E", position: 4}
          ]
        })

      assert %{options: ["must have at most 4 options"]} = errors_on(changeset)
    end

    test "rejects closes_at in the past" do
      past = DateTime.utc_now() |> DateTime.add(-3600, :second)

      changeset =
        Poll.changeset(%Poll{}, %{
          mode: "single",
          article_id: 1,
          closes_at: past,
          options: [
            %{text: "A", position: 0},
            %{text: "B", position: 1}
          ]
        })

      assert %{closes_at: ["must be in the future"]} = errors_on(changeset)
    end

    test "accepts closes_at in the future" do
      future = DateTime.utc_now() |> DateTime.add(3600, :second)

      changeset =
        Poll.changeset(%Poll{}, %{
          mode: "single",
          article_id: 1,
          closes_at: future,
          options: [
            %{text: "A", position: 0},
            %{text: "B", position: 1}
          ]
        })

      assert changeset.valid?
    end
  end

  describe "Poll.closed?/1" do
    test "returns false when closes_at is nil" do
      refute Poll.closed?(%Poll{closes_at: nil})
    end

    test "returns false when closes_at is in the future" do
      future = DateTime.utc_now() |> DateTime.add(3600, :second)
      refute Poll.closed?(%Poll{closes_at: future})
    end

    test "returns true when closes_at is in the past" do
      past = DateTime.utc_now() |> DateTime.add(-3600, :second)
      assert Poll.closed?(%Poll{closes_at: past})
    end
  end

  describe "PollOption.changeset/2" do
    test "validates text max length of 200" do
      changeset =
        PollOption.changeset(%PollOption{}, %{
          text: String.duplicate("a", 201),
          position: 0
        })

      assert %{text: _} = errors_on(changeset)
    end

    test "valid with text up to 200 chars" do
      changeset =
        PollOption.changeset(%PollOption{}, %{
          text: String.duplicate("a", 200),
          position: 0
        })

      assert changeset.valid?
    end
  end
end
