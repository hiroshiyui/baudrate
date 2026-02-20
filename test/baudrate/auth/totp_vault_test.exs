defmodule Baudrate.Auth.TotpVaultTest do
  use ExUnit.Case, async: true

  alias Baudrate.Auth.TotpVault

  describe "encrypt/1 and decrypt/1" do
    test "round-trip preserves plaintext" do
      secret = :crypto.strong_rand_bytes(20)
      encrypted = TotpVault.encrypt(secret)
      assert {:ok, ^secret} = TotpVault.decrypt(encrypted)
    end

    test "encrypted output differs from plaintext" do
      secret = :crypto.strong_rand_bytes(20)
      encrypted = TotpVault.encrypt(secret)
      refute encrypted == secret
    end

    test "encrypted output has correct structure (12 IV + 16 tag + ciphertext)" do
      secret = :crypto.strong_rand_bytes(20)
      encrypted = TotpVault.encrypt(secret)
      # 12 (IV) + 16 (tag) + 20 (ciphertext for 20-byte secret)
      assert byte_size(encrypted) == 48
    end

    test "each encryption produces a unique ciphertext (random IV)" do
      secret = :crypto.strong_rand_bytes(20)
      encrypted1 = TotpVault.encrypt(secret)
      encrypted2 = TotpVault.encrypt(secret)
      refute encrypted1 == encrypted2
    end

    test "both decrypt to the same plaintext" do
      secret = :crypto.strong_rand_bytes(20)
      encrypted1 = TotpVault.encrypt(secret)
      encrypted2 = TotpVault.encrypt(secret)
      assert {:ok, ^secret} = TotpVault.decrypt(encrypted1)
      assert {:ok, ^secret} = TotpVault.decrypt(encrypted2)
    end
  end

  describe "decrypt/1 tamper detection" do
    test "returns :error when ciphertext is tampered" do
      secret = :crypto.strong_rand_bytes(20)
      encrypted = TotpVault.encrypt(secret)

      # Flip a bit in the ciphertext portion (after IV + tag = 28 bytes)
      <<iv_tag::binary-28, ciphertext::binary>> = encrypted
      tampered_byte = :crypto.exor(binary_part(ciphertext, 0, 1), <<0x01>>)
      tampered = iv_tag <> tampered_byte <> binary_part(ciphertext, 1, byte_size(ciphertext) - 1)

      assert :error = TotpVault.decrypt(tampered)
    end

    test "returns :error when tag is tampered" do
      secret = :crypto.strong_rand_bytes(20)
      encrypted = TotpVault.encrypt(secret)

      <<iv::binary-12, tag::binary-16, ciphertext::binary>> = encrypted
      tampered_tag = :crypto.exor(binary_part(tag, 0, 1), <<0x01>>)
      tampered = iv <> tampered_tag <> binary_part(tag, 1, 15) <> ciphertext

      assert :error = TotpVault.decrypt(tampered)
    end

    test "returns :error when IV is tampered" do
      secret = :crypto.strong_rand_bytes(20)
      encrypted = TotpVault.encrypt(secret)

      <<iv::binary-12, rest::binary>> = encrypted
      tampered_iv = :crypto.exor(binary_part(iv, 0, 1), <<0x01>>)
      tampered = tampered_iv <> binary_part(iv, 1, 11) <> rest

      assert :error = TotpVault.decrypt(tampered)
    end

    test "returns :error for truncated input" do
      secret = :crypto.strong_rand_bytes(20)
      encrypted = TotpVault.encrypt(secret)
      truncated = binary_part(encrypted, 0, 20)

      assert :error = TotpVault.decrypt(truncated)
    end

    test "returns :error for empty binary" do
      assert :error = TotpVault.decrypt(<<>>)
    end

    test "returns :error for nil" do
      assert :error = TotpVault.decrypt(nil)
    end

    test "returns :error for non-binary input" do
      assert :error = TotpVault.decrypt(12345)
    end
  end
end
