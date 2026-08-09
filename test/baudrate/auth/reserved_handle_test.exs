defmodule Baudrate.Auth.ReservedHandleTest do
  use Baudrate.DataCase, async: true

  alias Baudrate.Auth.ReservedHandle
  alias Baudrate.Repo

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        handle: "alice",
        handle_type: "user",
        reserved_at: DateTime.utc_now() |> DateTime.truncate(:second)
      },
      overrides
    )
  end

  describe "changeset/2" do
    test "accepts a user handle and a board handle" do
      assert ReservedHandle.changeset(%ReservedHandle{}, attrs()).valid?
      assert ReservedHandle.changeset(%ReservedHandle{}, attrs(%{handle_type: "board"})).valid?
    end

    test "requires handle, handle_type, and reserved_at" do
      changeset = ReservedHandle.changeset(%ReservedHandle{}, %{})
      refute changeset.valid?
      errors = errors_on(changeset)
      assert errors[:handle]
      assert errors[:handle_type]
      assert errors[:reserved_at]
    end

    test "rejects an unknown handle_type" do
      changeset = ReservedHandle.changeset(%ReservedHandle{}, attrs(%{handle_type: "instance"}))
      refute changeset.valid?
      assert errors_on(changeset)[:handle_type]
    end

    test "downcases the handle so reservation is case-insensitive" do
      changeset = ReservedHandle.changeset(%ReservedHandle{}, attrs(%{handle: "AlIcE"}))
      assert Ecto.Changeset.get_change(changeset, :handle) == "alice"
    end

    test "a handle can only be reserved once, regardless of case" do
      assert {:ok, _} = %ReservedHandle{} |> ReservedHandle.changeset(attrs()) |> Repo.insert()

      assert {:error, changeset} =
               %ReservedHandle{}
               |> ReservedHandle.changeset(attrs(%{handle: "ALICE", handle_type: "board"}))
               |> Repo.insert()

      assert errors_on(changeset)[:handle]
    end
  end
end
