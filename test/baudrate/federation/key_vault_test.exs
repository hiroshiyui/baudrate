defmodule Baudrate.Federation.KeyVaultTest do
  use ExUnit.Case, async: true

  alias Baudrate.Crypto.Vault
  alias Baudrate.Federation.KeyVault

  # Actor structs are all the vault needs: they bind a key to its actor.
  @user %Baudrate.Setup.User{id: 17}

  describe "encrypt/2 and decrypt/2" do
    test "round-trip preserves plaintext" do
      pem = "-----BEGIN RSA PRIVATE KEY-----\nfake-key-data\n-----END RSA PRIVATE KEY-----"
      encrypted = KeyVault.encrypt(pem, @user)
      assert {:ok, ^pem} = KeyVault.decrypt(encrypted, @user)
    end

    test "encrypted output differs from plaintext" do
      pem = :crypto.strong_rand_bytes(100)
      encrypted = KeyVault.encrypt(pem, @user)
      refute encrypted == pem
    end

    test "records which key encrypted it, so a rotation knows what to rewrite" do
      assert {:ok, "testsign"} = Vault.key_id(KeyVault.encrypt("pem", @user))
    end

    test "a key written for one actor does not decrypt for another" do
      encrypted = KeyVault.encrypt("pem", @user)

      assert :error = KeyVault.decrypt(encrypted, %Baudrate.Content.Board{id: @user.id})
      assert :error = KeyVault.decrypt(encrypted, :site)
    end

    test "each encryption produces a unique ciphertext (random IV)" do
      plaintext = :crypto.strong_rand_bytes(50)
      encrypted1 = KeyVault.encrypt(plaintext, @user)
      encrypted2 = KeyVault.encrypt(plaintext, @user)
      refute encrypted1 == encrypted2
    end

    test "both decrypt to the same plaintext" do
      plaintext = :crypto.strong_rand_bytes(50)
      encrypted1 = KeyVault.encrypt(plaintext, @user)
      encrypted2 = KeyVault.encrypt(plaintext, @user)
      assert {:ok, ^plaintext} = KeyVault.decrypt(encrypted1, @user)
      assert {:ok, ^plaintext} = KeyVault.decrypt(encrypted2, @user)
    end
  end

  describe "decrypt/2 tamper detection" do
    test "returns :error when any byte of the stored value is flipped" do
      blob = KeyVault.encrypt("pem", @user)

      for offset <- [0, 4, div(byte_size(blob), 2), byte_size(blob) - 1] do
        <<before::binary-size(offset), byte::8, rest::binary>> = blob
        tampered = <<before::binary, Bitwise.bxor(byte, 1)::8, rest::binary>>

        assert :error = KeyVault.decrypt(tampered, @user), "flipping byte #{offset} was accepted"
      end
    end

    test "returns :error for truncated input" do
      plaintext = :crypto.strong_rand_bytes(50)
      encrypted = KeyVault.encrypt(plaintext, @user)
      truncated = binary_part(encrypted, 0, 20)

      assert :error = KeyVault.decrypt(truncated, @user)
    end

    test "returns :error for empty binary" do
      assert :error = KeyVault.decrypt(<<>>, @user)
    end

    test "returns :error for nil" do
      assert :error = KeyVault.decrypt(nil, @user)
    end

    test "returns :error for non-binary input" do
      assert :error = KeyVault.decrypt(12_345, @user)
    end
  end
end
