defmodule Baudrate.Setup.SettingsCacheTest do
  use Baudrate.DataCase, async: false

  alias Baudrate.Setup
  alias Baudrate.Setup.SettingsCache

  describe "get/1" do
    test "returns nil for unknown key" do
      assert SettingsCache.get("nonexistent_key") == nil
    end

    test "returns value after put" do
      SettingsCache.put("test_cache_key", "test_value")

      assert SettingsCache.get("test_cache_key") == "test_value"
    end
  end

  describe "put/2" do
    test "updates a single key without affecting others" do
      SettingsCache.put("key_a", "value_a")
      SettingsCache.put("key_b", "value_b")

      assert SettingsCache.get("key_a") == "value_a"
      assert SettingsCache.get("key_b") == "value_b"

      # Update key_a without affecting key_b
      SettingsCache.put("key_a", "new_value_a")

      assert SettingsCache.get("key_a") == "new_value_a"
      assert SettingsCache.get("key_b") == "value_b"
    end
  end

  describe "refresh/0" do
    test "loads all settings from database" do
      Setup.set_setting("refresh_test", "db_value")
      SettingsCache.refresh()

      assert SettingsCache.get("refresh_test") == "db_value"
    end

    test "removes deleted settings from cache" do
      Setup.set_setting("ephemeral_key", "will_be_deleted")
      SettingsCache.refresh()

      assert SettingsCache.get("ephemeral_key") == "will_be_deleted"

      # Delete the setting directly from the DB
      Baudrate.Repo.delete_all(from s in Baudrate.Setup.Setting, where: s.key == "ephemeral_key")

      SettingsCache.refresh()

      assert SettingsCache.get("ephemeral_key") == nil
    end

    test "reflects updated values after refresh" do
      Setup.set_setting("refresh_update", "original")
      SettingsCache.refresh()

      assert SettingsCache.get("refresh_update") == "original"

      Setup.set_setting("refresh_update", "updated")
      SettingsCache.refresh()

      assert SettingsCache.get("refresh_update") == "updated"
    end
  end
end
