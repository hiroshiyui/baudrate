defmodule Baudrate.Crypto.KeyringTest do
  # Configures application-wide key material.
  use ExUnit.Case, async: false

  alias Baudrate.Crypto.Keyring

  setup do
    original = Application.get_env(:baudrate, Keyring)
    on_exit(fn -> restore(original) end)
    :ok
  end

  defp restore(nil), do: Application.delete_env(:baudrate, Keyring)
  defp restore(config), do: Application.put_env(:baudrate, Keyring, config)

  defp key, do: :crypto.strong_rand_bytes(32)

  describe "without configured keys" do
    test "falls back to the secret_key_base derivation, under the legacy id" do
      Application.delete_env(:baudrate, Keyring)

      for purpose <- Map.keys(Keyring.purposes()) do
        assert {"legacy", derived} = Keyring.current(purpose)
        assert byte_size(derived) == 32
        assert {:ok, ^derived} = Keyring.fetch(purpose, "legacy")
      end

      refute Keyring.separated?(:auth)
      refute Keyring.separated?(:signing)
      assert Keyring.configured_ids(:auth) == []
    end

    test "the fallback key differs per purpose, as it always has" do
      Application.delete_env(:baudrate, Keyring)

      {_, totp} = Keyring.current(:totp)
      {_, recovery} = Keyring.current(:recovery_code)
      {_, federation} = Keyring.current(:federation)
      {_, vapid} = Keyring.current(:vapid)

      assert Enum.uniq([totp, recovery, federation, vapid]) |> length() == 4
    end
  end

  describe "with configured keys" do
    test "the first key of a class is current, and retired keys stay readable" do
      auth = [%{id: "k2", key: key()}, %{id: "k1", key: key()}]
      Application.put_env(:baudrate, Keyring, auth_keys: auth)

      assert {"k2", current} = Keyring.current(:totp)
      assert {:ok, ^current} = Keyring.fetch(:totp, "k2")
      assert {:ok, retired} = Keyring.fetch(:totp, "k1")
      refute retired == current
      assert Keyring.configured_ids(:auth) == ["k2", "k1"]
      assert Keyring.separated?(:auth)
    end

    test "each purpose gets its own subkey from the same class key" do
      shared = key()
      Application.put_env(:baudrate, Keyring, auth_keys: [%{id: "k1", key: shared}])

      {_, totp} = Keyring.current(:totp)
      {_, recovery} = Keyring.current(:recovery_code)

      refute totp == recovery
      refute totp == shared
    end

    test "a class is configured on its own" do
      Application.put_env(:baudrate, Keyring, signing_keys: [%{id: "s1", key: key()}])

      assert Keyring.separated?(:signing)
      refute Keyring.separated?(:auth)
      assert {"legacy", _} = Keyring.current(:totp)
      assert {"s1", _} = Keyring.current(:federation)
    end

    test "an id this instance has no key for is refused" do
      Application.put_env(:baudrate, Keyring, auth_keys: [%{id: "k1", key: key()}])

      assert :error = Keyring.fetch(:totp, "k9")
      assert :error = Keyring.fetch(:totp, nil)
    end

    test "the legacy key stays available while keys are configured" do
      Application.put_env(:baudrate, Keyring, auth_keys: [%{id: "k1", key: key()}])

      assert {:ok, derived} = Keyring.fetch(:totp, "legacy")
      assert byte_size(derived) == 32
    end
  end

  test "an unknown purpose is a programming error" do
    assert_raise ArgumentError, fn -> Keyring.current(:nonsense) end
  end
end
