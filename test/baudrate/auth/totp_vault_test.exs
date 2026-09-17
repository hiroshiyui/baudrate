defmodule Baudrate.Auth.TotpVaultTest do
  use ExUnit.Case, async: true

  alias Baudrate.Auth.TotpVault
  alias Baudrate.Crypto.Vault

  # A user struct is all the vault needs: it binds a secret to the member id.
  @user %Baudrate.Setup.User{id: 4242}

  describe "encrypt/2 and decrypt/2" do
    test "round-trip preserves plaintext" do
      secret = :crypto.strong_rand_bytes(20)
      encrypted = TotpVault.encrypt(secret, @user)
      assert {:ok, ^secret} = TotpVault.decrypt(encrypted, @user)
    end

    test "encrypted output differs from plaintext" do
      secret = :crypto.strong_rand_bytes(20)
      encrypted = TotpVault.encrypt(secret, @user)
      refute encrypted == secret
    end

    test "records which key encrypted it, so a rotation knows what to rewrite" do
      secret = :crypto.strong_rand_bytes(20)

      assert {:ok, "testauth"} = Vault.key_id(TotpVault.encrypt(secret, @user))
    end

    test "a secret written for one member does not decrypt for another" do
      secret = :crypto.strong_rand_bytes(20)
      encrypted = TotpVault.encrypt(secret, @user)

      assert :error = TotpVault.decrypt(encrypted, %Baudrate.Setup.User{id: @user.id + 1})
    end

    test "each encryption produces a unique ciphertext (random IV)" do
      secret = :crypto.strong_rand_bytes(20)
      encrypted1 = TotpVault.encrypt(secret, @user)
      encrypted2 = TotpVault.encrypt(secret, @user)
      refute encrypted1 == encrypted2
    end

    test "both decrypt to the same plaintext" do
      secret = :crypto.strong_rand_bytes(20)
      encrypted1 = TotpVault.encrypt(secret, @user)
      encrypted2 = TotpVault.encrypt(secret, @user)
      assert {:ok, ^secret} = TotpVault.decrypt(encrypted1, @user)
      assert {:ok, ^secret} = TotpVault.decrypt(encrypted2, @user)
    end
  end

  describe "decrypt/2 tamper detection" do
    test "returns :error when any byte of the stored value is flipped" do
      secret = :crypto.strong_rand_bytes(20)
      blob = TotpVault.encrypt(secret, @user)

      for offset <- [0, 4, div(byte_size(blob), 2), byte_size(blob) - 1] do
        <<before::binary-size(offset), byte::8, rest::binary>> = blob
        tampered = <<before::binary, Bitwise.bxor(byte, 1)::8, rest::binary>>

        assert :error = TotpVault.decrypt(tampered, @user), "flipping byte #{offset} was accepted"
      end
    end

    test "returns :error for truncated input" do
      secret = :crypto.strong_rand_bytes(20)
      encrypted = TotpVault.encrypt(secret, @user)
      truncated = binary_part(encrypted, 0, 20)

      assert :error = TotpVault.decrypt(truncated, @user)
    end

    test "returns :error for empty binary" do
      assert :error = TotpVault.decrypt(<<>>, @user)
    end

    test "returns :error for nil" do
      assert :error = TotpVault.decrypt(nil, @user)
    end

    test "returns :error for non-binary input" do
      assert :error = TotpVault.decrypt(12_345, @user)
    end
  end
end
