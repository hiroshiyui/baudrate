defmodule Baudrate.Notification.VapidVaultTest do
  use ExUnit.Case, async: true

  alias Baudrate.Notification.VapidVault

  describe "encrypt/1 and decrypt/1" do
    test "round-trip preserves plaintext" do
      key = :crypto.strong_rand_bytes(32)
      encrypted = VapidVault.encrypt(key)
      assert {:ok, ^key} = VapidVault.decrypt(encrypted)
    end

    test "encrypted output differs from plaintext" do
      key = :crypto.strong_rand_bytes(32)
      encrypted = VapidVault.encrypt(key)
      refute encrypted == key
    end

    test "encrypted output has correct structure (12 IV + 16 tag + ciphertext)" do
      plaintext = :crypto.strong_rand_bytes(32)
      encrypted = VapidVault.encrypt(plaintext)
      # 12 (IV) + 16 (tag) + 32 (ciphertext for 32-byte plaintext)
      assert byte_size(encrypted) == 60
    end

    test "each encryption produces a unique ciphertext (random IV)" do
      plaintext = :crypto.strong_rand_bytes(32)
      encrypted1 = VapidVault.encrypt(plaintext)
      encrypted2 = VapidVault.encrypt(plaintext)
      refute encrypted1 == encrypted2
    end

    test "both decrypt to the same plaintext" do
      plaintext = :crypto.strong_rand_bytes(32)
      encrypted1 = VapidVault.encrypt(plaintext)
      encrypted2 = VapidVault.encrypt(plaintext)
      assert {:ok, ^plaintext} = VapidVault.decrypt(encrypted1)
      assert {:ok, ^plaintext} = VapidVault.decrypt(encrypted2)
    end
  end

  describe "decrypt/1 tamper detection" do
    test "returns :error when ciphertext is tampered" do
      plaintext = :crypto.strong_rand_bytes(32)
      encrypted = VapidVault.encrypt(plaintext)

      <<iv_tag::binary-28, ciphertext::binary>> = encrypted
      tampered_byte = :crypto.exor(binary_part(ciphertext, 0, 1), <<0x01>>)
      tampered = iv_tag <> tampered_byte <> binary_part(ciphertext, 1, byte_size(ciphertext) - 1)

      assert :error = VapidVault.decrypt(tampered)
    end

    test "returns :error when tag is tampered" do
      plaintext = :crypto.strong_rand_bytes(32)
      encrypted = VapidVault.encrypt(plaintext)

      <<iv::binary-12, tag::binary-16, ciphertext::binary>> = encrypted
      tampered_tag = :crypto.exor(binary_part(tag, 0, 1), <<0x01>>)
      tampered = iv <> tampered_tag <> binary_part(tag, 1, 15) <> ciphertext

      assert :error = VapidVault.decrypt(tampered)
    end

    test "returns :error when IV is tampered" do
      plaintext = :crypto.strong_rand_bytes(32)
      encrypted = VapidVault.encrypt(plaintext)

      <<iv::binary-12, rest::binary>> = encrypted
      tampered_iv = :crypto.exor(binary_part(iv, 0, 1), <<0x01>>)
      tampered = tampered_iv <> binary_part(iv, 1, 11) <> rest

      assert :error = VapidVault.decrypt(tampered)
    end

    test "returns :error for truncated input" do
      plaintext = :crypto.strong_rand_bytes(32)
      encrypted = VapidVault.encrypt(plaintext)
      truncated = binary_part(encrypted, 0, 20)

      assert :error = VapidVault.decrypt(truncated)
    end

    test "returns :error for empty binary" do
      assert :error = VapidVault.decrypt(<<>>)
    end

    test "returns :error for nil" do
      assert :error = VapidVault.decrypt(nil)
    end

    test "returns :error for non-binary input" do
      assert :error = VapidVault.decrypt(12345)
    end
  end
end
