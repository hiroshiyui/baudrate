defmodule Baudrate.Media.ProxyTest do
  use ExUnit.Case, async: true

  alias Baudrate.Media.Proxy

  describe "url/1" do
    test "rewrites an https URL to a signed proxy path" do
      assert "/media/" <> rest = Proxy.url("https://remote.example/photo.png")
      assert [sig, encoded] = String.split(rest, "/", parts: 2)
      assert {:ok, "https://remote.example/photo.png"} = Proxy.verify(sig, encoded)
    end

    test "rewrites an http URL" do
      assert "/media/" <> _ = Proxy.url("http://remote.example/photo.png")
    end

    test "rewrites a protocol-relative URL" do
      # The classic way to smuggle a third-party request past a scheme filter.
      assert "/media/" <> rest = Proxy.url("//remote.example/photo.png")
      [sig, encoded] = String.split(rest, "/", parts: 2)
      assert {:ok, "//remote.example/photo.png"} = Proxy.verify(sig, encoded)
    end

    test "passes local paths through untouched" do
      assert Proxy.url("/uploads/avatars/abc/48.webp") == "/uploads/avatars/abc/48.webp"
      assert Proxy.url("/images/logo.svg") == "/images/logo.svg"
    end

    test "is idempotent — an already-proxied path is not re-wrapped" do
      once = Proxy.url("https://remote.example/photo.png")
      assert Proxy.url(once) == once
    end

    test "returns nil for nil" do
      assert Proxy.url(nil) == nil
    end

    test "is deterministic so browser caching and LiveView diffing still work" do
      # Phoenix.Token would embed a timestamp here and mint a different URL on
      # every render, producing an avatar diff on every LiveView patch.
      url = "https://remote.example/avatar.png"
      assert Proxy.url(url) == Proxy.url(url)
    end
  end

  describe "verify/2" do
    test "rejects a forged signature" do
      "/media/" <> rest = Proxy.url("https://remote.example/photo.png")
      [_sig, encoded] = String.split(rest, "/", parts: 2)

      assert {:error, :bad_signature} = Proxy.verify(String.duplicate("a", 32), encoded)
    end

    test "rejects a tampered payload" do
      "/media/" <> rest = Proxy.url("https://remote.example/photo.png")
      [sig, _encoded] = String.split(rest, "/", parts: 2)

      tampered = Base.url_encode64("https://evil.example/photo.png", padding: false)
      assert {:error, :bad_signature} = Proxy.verify(sig, tampered)
    end

    test "rejects malformed base64" do
      assert {:error, :bad_encoding} = Proxy.verify("sig", "!!!not base64!!!")
    end

    test "rejects a correctly signed local path" do
      # Even with a valid signature the endpoint must not be steerable at a
      # local path.
      local = "/etc/passwd"
      sig = Proxy.sign(local)
      encoded = Base.url_encode64(local, padding: false)

      assert {:error, :not_remote} = Proxy.verify(sig, encoded)
    end

    test "rejects non-binary input" do
      assert {:error, :bad_encoding} = Proxy.verify(nil, nil)
    end
  end

  describe "remote?/1" do
    test "classifies schemes" do
      assert Proxy.remote?("https://x.example/a.png")
      assert Proxy.remote?("http://x.example/a.png")
      assert Proxy.remote?("//x.example/a.png")
      refute Proxy.remote?("/uploads/a.webp")
      refute Proxy.remote?("a.png")
      refute Proxy.remote?(nil)
    end
  end
end
