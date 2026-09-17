defmodule Baudrate.Crypto.RuntimeKeysTest do
  @moduledoc """
  Reads `config/runtime.exs` the way a release does, to check that the
  environment variables holding the encryption keys are parsed and validated
  (ADR 0038). A key that is accepted here but wrong would write secrets nobody
  can read afterwards, so the validation is worth testing rather than trusting.
  """

  # Sets environment variables.
  use ExUnit.Case, async: false

  @key32 Base.encode64(:crypto.strong_rand_bytes(32))
  @other32 Base.encode64(:crypto.strong_rand_bytes(32))

  setup do
    previous =
      Map.new(
        [
          "DATABASE_URL",
          "SECRET_KEY_BASE",
          "PHX_HOST",
          "BAUDRATE_AUTH_KEYS",
          "BAUDRATE_SIGNING_KEYS"
        ],
        &{&1, System.get_env(&1)}
      )

    System.put_env("DATABASE_URL", "ecto://user:pass@localhost/baudrate_runtime_test")
    System.put_env("SECRET_KEY_BASE", String.duplicate("s", 64))
    System.put_env("PHX_HOST", "example.test")
    System.delete_env("BAUDRATE_AUTH_KEYS")
    System.delete_env("BAUDRATE_SIGNING_KEYS")

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  defp keyring do
    Config.Reader.read!("config/runtime.exs", env: :prod)
    |> get_in([:baudrate, Baudrate.Crypto.Keyring])
  end

  test "unset variables mean the secret_key_base fallback" do
    assert keyring() == [auth_keys: [], signing_keys: []]
  end

  test "reads a class's keys, current first" do
    System.put_env("BAUDRATE_AUTH_KEYS", "k2:#{@key32}, k1:#{@other32}")
    System.put_env("BAUDRATE_SIGNING_KEYS", "s1:#{@key32}")

    config = keyring()

    assert [%{id: "k2", key: current}, %{id: "k1", key: retired}] = config[:auth_keys]
    assert byte_size(current) == 32
    assert byte_size(retired) == 32
    assert [%{id: "s1"}] = config[:signing_keys]
  end

  test "refuses a key that is not 32 bytes" do
    System.put_env("BAUDRATE_AUTH_KEYS", "k1:#{Base.encode64(:crypto.strong_rand_bytes(16))}")

    assert_raise RuntimeError, ~r/decodes to 16 bytes, not 32/, &keyring/0
  end

  test "refuses a key that is not Base64" do
    System.put_env("BAUDRATE_AUTH_KEYS", "k1:not base64!!")

    assert_raise RuntimeError, ~r/is not Base64/, &keyring/0
  end

  test "refuses an entry without an id" do
    System.put_env("BAUDRATE_SIGNING_KEYS", @key32)

    assert_raise RuntimeError, ~r/expected `id:key`/, &keyring/0
  end

  test "refuses an id that could not appear in a stored value" do
    System.put_env("BAUDRATE_AUTH_KEYS", "not an id:#{@key32}")

    assert_raise RuntimeError, ~r/bad id/, &keyring/0
  end

  test "refuses the same id twice, since an id names one key" do
    System.put_env("BAUDRATE_AUTH_KEYS", "k1:#{@key32},k1:#{@other32}")

    assert_raise RuntimeError, ~r/lists the same id twice/, &keyring/0
  end

  test "the error says how to generate a key and never prints one" do
    System.put_env("BAUDRATE_AUTH_KEYS", "k1:short")

    error = assert_raise RuntimeError, fn -> keyring() end
    message = error.message

    assert message =~ "openssl rand -base64 32"
    assert message =~ "doc/sysop.md"
    refute message =~ "short"
  end
end
