defmodule Baudrate.ReleaseTest do
  use Baudrate.DataCase, async: true

  alias Baudrate.Release

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
end
