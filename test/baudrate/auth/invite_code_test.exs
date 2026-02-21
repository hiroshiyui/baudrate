defmodule Baudrate.Auth.InviteCodeTest do
  use Baudrate.DataCase

  alias Baudrate.Auth.InviteCode

  describe "changeset/2" do
    test "valid with required fields" do
      changeset = InviteCode.changeset(%InviteCode{}, %{code: "abcd1234", created_by_id: 1})
      assert changeset.valid?
    end

    test "invalid without code" do
      changeset = InviteCode.changeset(%InviteCode{}, %{created_by_id: 1})
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).code
    end

    test "invalid without created_by_id" do
      changeset = InviteCode.changeset(%InviteCode{}, %{code: "abcd1234"})
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).created_by_id
    end

    test "accepts optional fields" do
      changeset =
        InviteCode.changeset(%InviteCode{}, %{
          code: "abcd1234",
          created_by_id: 1,
          max_uses: 5,
          expires_at: DateTime.utc_now()
        })

      assert changeset.valid?
    end
  end

  describe "revoke_changeset/1" do
    test "sets revoked to true" do
      changeset = InviteCode.revoke_changeset(%InviteCode{revoked: false})
      assert Ecto.Changeset.get_change(changeset, :revoked) == true
    end
  end
end
