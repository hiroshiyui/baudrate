defmodule Baudrate.Setup.SettingTest do
  use Baudrate.DataCase, async: true

  alias Baudrate.Setup.Setting

  describe "changeset/2" do
    test "valid changeset with key and value" do
      changeset = Setting.changeset(%Setting{}, %{key: "site_name", value: "My Site"})
      assert changeset.valid?
    end

    test "requires key" do
      changeset = Setting.changeset(%Setting{}, %{value: "My Site"})
      assert %{key: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires value" do
      changeset = Setting.changeset(%Setting{}, %{key: "site_name"})
      assert %{value: ["can't be blank"]} = errors_on(changeset)
    end

    test "enforces unique key constraint" do
      {:ok, _} = Repo.insert(Setting.changeset(%Setting{}, %{key: "test_key", value: "val"}))

      {:error, changeset} =
        Repo.insert(Setting.changeset(%Setting{}, %{key: "test_key", value: "other"}))

      assert %{key: ["has already been taken"]} = errors_on(changeset)
    end
  end
end
