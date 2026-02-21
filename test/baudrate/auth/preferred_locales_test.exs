defmodule Baudrate.Auth.PreferredLocalesTest do
  use Baudrate.DataCase, async: true

  alias Baudrate.Auth

  setup do
    user = BaudrateWeb.ConnCase.setup_user("user")
    {:ok, user: user}
  end

  describe "update_preferred_locales/2" do
    test "sets valid locales", %{user: user} do
      assert {:ok, updated} = Auth.update_preferred_locales(user, ["zh_TW", "en"])
      assert updated.preferred_locales == ["zh_TW", "en"]
    end

    test "allows empty list", %{user: user} do
      # First set some locales
      {:ok, user} = Auth.update_preferred_locales(user, ["zh_TW"])
      # Then clear them
      assert {:ok, updated} = Auth.update_preferred_locales(user, [])
      assert updated.preferred_locales == []
    end

    test "rejects unknown locales", %{user: user} do
      assert {:error, changeset} = Auth.update_preferred_locales(user, ["xx_YY"])
      assert errors_on(changeset).preferred_locales != []
    end

    test "rejects mix of valid and invalid", %{user: user} do
      assert {:error, changeset} = Auth.update_preferred_locales(user, ["en", "invalid"])
      assert errors_on(changeset).preferred_locales != []
    end

    test "allows single locale", %{user: user} do
      assert {:ok, updated} = Auth.update_preferred_locales(user, ["en"])
      assert updated.preferred_locales == ["en"]
    end
  end
end
