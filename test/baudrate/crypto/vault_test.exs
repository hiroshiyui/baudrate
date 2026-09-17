defmodule Baudrate.Crypto.VaultTest do
  # Configures application-wide key material.
  use ExUnit.Case, async: false

  alias Baudrate.Crypto.{Keyring, Vault}

  setup do
    original = Application.get_env(:baudrate, Keyring)
    on_exit(fn -> restore(original) end)
    :ok
  end

  defp restore(nil), do: Application.delete_env(:baudrate, Keyring)
  defp restore(config), do: Application.put_env(:baudrate, Keyring, config)

  defp key, do: :crypto.strong_rand_bytes(32)

  defp configure(keys), do: Application.put_env(:baudrate, Keyring, keys)

  describe "on the secret_key_base fallback" do
    setup do
      Application.delete_env(:baudrate, Keyring)
      :ok
    end

    test "writes the old format, so a release without the keyring can read it" do
      blob = Vault.encrypt(:totp, "secret", {:user, 1})

      # iv(12) + tag(16) + ciphertext, with no header.
      assert byte_size(blob) == 12 + 16 + byte_size("secret")
      refute match?(<<"BK1", _::binary>>, blob)
      assert {:ok, "legacy"} = Vault.key_id(blob)
    end

    test "is not bound to a row, which is what rotating fixes" do
      blob = Vault.encrypt(:totp, "secret", {:user, 1})

      assert {:ok, "secret"} = Vault.decrypt(:totp, blob, {:user, 2})
    end
  end

  describe "with configured keys" do
    setup do
      configure(auth_keys: [%{id: "k1", key: key()}], signing_keys: [%{id: "s1", key: key()}])
      :ok
    end

    test "writes a self-describing value that records its key" do
      blob = Vault.encrypt(:totp, "secret", {:user, 1})

      assert <<"BK1", 2, "k1", _rest::binary>> = blob
      assert {:ok, "k1"} = Vault.key_id(blob)
      assert {:ok, "secret"} = Vault.decrypt(:totp, blob, {:user, 1})
    end

    test "refuses a value moved to another row" do
      blob = Vault.encrypt(:totp, "secret", {:user, 1})

      assert :error = Vault.decrypt(:totp, blob, {:user, 2})
      assert :error = Vault.decrypt(:totp, blob, {:board, 1})
      assert :error = Vault.decrypt(:totp, blob, {:setting, "whatever"})
    end

    test "refuses a value from another purpose" do
      blob = Vault.encrypt(:federation, "pem", {:user, 1})

      assert :error = Vault.decrypt(:totp, blob, {:user, 1})
      assert {:ok, "pem"} = Vault.decrypt(:federation, blob, {:user, 1})
    end

    test "still reads values written on the fallback" do
      Application.delete_env(:baudrate, Keyring)
      legacy = Vault.encrypt(:totp, "old secret", {:user, 1})

      configure(auth_keys: [%{id: "k1", key: key()}])

      assert {:ok, "old secret"} = Vault.decrypt(:totp, legacy, {:user, 1})
      assert {:ok, "legacy"} = Vault.key_id(legacy)
    end

    test "reads a value written under a retired key, and rewrites to the current one" do
      retired = key()
      configure(auth_keys: [%{id: "k1", key: retired}])
      blob = Vault.encrypt(:totp, "secret", {:user, 1})

      configure(auth_keys: [%{id: "k2", key: key()}, %{id: "k1", key: retired}])

      assert {:ok, "secret"} = Vault.decrypt(:totp, blob, {:user, 1})

      rewritten = Vault.encrypt(:totp, "secret", {:user, 1})
      assert {:ok, "k2"} = Vault.key_id(rewritten)
      assert {:ok, "secret"} = Vault.decrypt(:totp, rewritten, {:user, 1})
    end

    test "refuses a value whose key is no longer configured" do
      blob = Vault.encrypt(:totp, "secret", {:user, 1})

      configure(auth_keys: [%{id: "k2", key: key()}])

      assert :error = Vault.decrypt(:totp, blob, {:user, 1})
      # The census can still say which key it needs.
      assert {:ok, "k1"} = Vault.key_id(blob)
    end

    test "refuses tampering with the header, the tag or the ciphertext" do
      blob = Vault.encrypt(:totp, "secret", {:user, 1})

      <<"BK1", len, id::binary-size(len), iv::binary-12, tag::binary-16, ct::binary>> = blob

      assert :error =
               Vault.decrypt(
                 :totp,
                 <<"BK1", len, "kX", iv::binary, tag::binary, ct::binary>>,
                 {:user, 1}
               )

      assert :error =
               Vault.decrypt(
                 :totp,
                 <<"BK1", len, id::binary, iv::binary, tag::binary, "x">>,
                 {:user, 1}
               )

      flipped = :crypto.exor(binary_part(tag, 0, 1), <<1>>) <> binary_part(tag, 1, 15)

      assert :error =
               Vault.decrypt(
                 :totp,
                 <<"BK1", len, id::binary, iv::binary, flipped::binary, ct::binary>>,
                 {:user, 1}
               )
    end

    test "refuses values that are not ciphertext at all" do
      for blob <- [<<>>, "not ciphertext", :crypto.strong_rand_bytes(8), nil, 123] do
        assert :error = Vault.decrypt(:totp, blob, {:user, 1})
      end

      assert :error = Vault.key_id(<<>>)
      assert :error = Vault.key_id(nil)
    end
  end
end
