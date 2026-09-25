defmodule Baudrate.Notification.VapidVaultTest do
  use ExUnit.Case, async: true

  alias Baudrate.Crypto.Vault
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

    test "records which key encrypted it, so a rotation knows what to rewrite" do
      assert {:ok, "testsign"} = Vault.key_id(VapidVault.encrypt(:crypto.strong_rand_bytes(32)))
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
    test "returns :error when any byte of the stored value is flipped" do
      blob = VapidVault.encrypt(:crypto.strong_rand_bytes(32))

      for offset <- [0, 4, div(byte_size(blob), 2), byte_size(blob) - 1] do
        <<before::binary-size(^offset), byte::8, rest::binary>> = blob
        tampered = <<before::binary, Bitwise.bxor(byte, 1)::8, rest::binary>>

        assert :error = VapidVault.decrypt(tampered), "flipping byte #{offset} was accepted"
      end
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
      assert :error = VapidVault.decrypt(12_345)
    end
  end
end
