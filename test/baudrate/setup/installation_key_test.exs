defmodule Baudrate.Setup.InstallationKeyTest do
  use ExUnit.Case, async: false

  alias Baudrate.Setup.InstallationKey

  setup do
    key = Application.get_env(:baudrate, :installation_key)
    enforced = Application.get_env(:baudrate, :installation_key_enforced?)

    on_exit(fn ->
      restore(:installation_key, key)
      restore(:installation_key_enforced?, enforced)
    end)

    :ok
  end

  defp restore(_key, nil), do: :ok
  defp restore(key, value), do: Application.put_env(:baudrate, key, value)

  describe "configured_key/0" do
    test "returns nil when unset" do
      Application.delete_env(:baudrate, :installation_key)
      assert InstallationKey.configured_key() == nil
    end

    test "treats a blank value as absent, so INSTALLATION_KEY= is not a key" do
      Application.put_env(:baudrate, :installation_key, "")
      assert InstallationKey.configured_key() == nil
    end

    test "returns the configured key" do
      Application.put_env(:baudrate, :installation_key, "s3cret")
      assert InstallationKey.configured_key() == "s3cret"
    end
  end

  describe "enforced?/0 and status/0" do
    test "not enforced by default" do
      Application.delete_env(:baudrate, :installation_key_enforced?)
      refute InstallationKey.enforced?()
      assert InstallationKey.status() == :ok
    end

    test "enforced with no key configured reports :missing" do
      Application.put_env(:baudrate, :installation_key_enforced?, true)
      Application.delete_env(:baudrate, :installation_key)
      assert InstallationKey.status() == {:error, :missing}
    end

    test "enforced with a key configured is :ok" do
      Application.put_env(:baudrate, :installation_key_enforced?, true)
      Application.put_env(:baudrate, :installation_key, "s3cret")
      assert InstallationKey.status() == :ok
    end

    test "a non-true value does not enable enforcement" do
      Application.put_env(:baudrate, :installation_key_enforced?, "true")
      refute InstallationKey.enforced?()
    end
  end

  describe "verify/1" do
    test "matches the configured key" do
      Application.put_env(:baudrate, :installation_key, "s3cret")
      assert InstallationKey.verify("s3cret")
      refute InstallationKey.verify("wrong")
      refute InstallationKey.verify("s3cre")
    end

    test "is false — not a crash — when no key is configured" do
      # Reachable by pushing the verify_key event straight over the LiveView
      # socket; secure_compare/2 is guarded on two binaries and would raise.
      Application.delete_env(:baudrate, :installation_key)
      refute InstallationKey.verify("anything")
    end

    test "is false for non-binary submissions" do
      Application.put_env(:baudrate, :installation_key, "s3cret")
      refute InstallationKey.verify(nil)
      refute InstallationKey.verify(%{"key" => "s3cret"})
      refute InstallationKey.verify(["s3cret"])
    end
  end

  describe "log_boot_status/0" do
    test "returns :ok and never raises" do
      Application.put_env(:baudrate, :installation_key_enforced?, true)
      Application.delete_env(:baudrate, :installation_key)
      assert InstallationKey.log_boot_status() == :ok

      Application.put_env(:baudrate, :installation_key, "s3cret")
      assert InstallationKey.log_boot_status() == :ok
    end
  end
end
