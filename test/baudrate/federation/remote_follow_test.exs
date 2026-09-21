defmodule Baudrate.Federation.RemoteFollowTest do
  @moduledoc """
  The acceptance gate for "Follow from your instance" (Phase 4E).

  Two values here are chosen by somebody else: the domain, by a visitor who
  may be anonymous, and the subscribe template, by that domain's server. Every
  test below is about one of them not being trusted.

  The refusals matter more than the happy path, because each one is
  individually plausible to relax: the host check looks redundant next to the
  HTTPS check, the `{uri}` check looks like belt and braces, and the blocked
  domain check lives one module away in `Discovery.webfinger_document/3`.
  """
  use Baudrate.DataCase, async: false

  alias Baudrate.Federation.{DomainBlocks, HTTPClient, RemoteFollow}

  @actor "https://baudrate.test/ap/users/bob"

  defp webfinger(links) do
    Jason.encode!(%{"subject" => "acct:alice@remote.example", "links" => links})
  end

  defp subscribe_link(template) do
    [%{"rel" => "http://ostatus.org/schema/1.0/subscribe", "template" => template}]
  end

  defp stub_webfinger(body) do
    Req.Test.stub(HTTPClient, fn conn ->
      if String.contains?(conn.request_path, ".well-known/webfinger") do
        Plug.Conn.send_resp(conn, 200, body)
      else
        Plug.Conn.send_resp(conn, 404, "")
      end
    end)
  end

  describe "parse_handle/1" do
    test "accepts a handle with or without the leading @" do
      assert {:ok, {"alice", "remote.example"}} =
               RemoteFollow.parse_handle("@alice@remote.example")

      assert {:ok, {"alice", "remote.example"}} =
               RemoteFollow.parse_handle("alice@remote.example")
    end

    test "downcases the domain, because the template host is compared to it" do
      assert {:ok, {"alice", "remote.example"}} =
               RemoteFollow.parse_handle("@alice@REMOTE.Example")
    end

    test "refuses anything that is not exactly user@domain" do
      for bad <- [
            "alice",
            "@alice",
            "alice@",
            "@alice@",
            "alice@remote.example@evil.example",
            "alice@localhost",
            "alice@remote.example/path",
            "alice@remote.example:8443",
            "al ice@remote.example",
            "alice@-remote.example",
            "alice@remote..example",
            "<script>@remote.example"
          ] do
        assert {:error, :invalid_handle} = RemoteFollow.parse_handle(bad),
               "#{inspect(bad)} was accepted as a handle"
      end
    end

    test "refuses a non-binary" do
      assert {:error, :invalid_handle} = RemoteFollow.parse_handle(nil)
    end
  end

  describe "subscribe_url/2" do
    test "substitutes the actor URI into the discovered template" do
      stub_webfinger(
        webfinger(subscribe_link("https://remote.example/authorize_interaction?uri={uri}"))
      )

      assert {:ok, url} = RemoteFollow.subscribe_url("@alice@remote.example", @actor)

      assert url ==
               "https://remote.example/authorize_interaction?uri=" <>
                 URI.encode_www_form(@actor)
    end

    test "encodes the actor URI, so the query string survives it" do
      stub_webfinger(webfinger(subscribe_link("https://remote.example/sub?uri={uri}&x=1")))

      assert {:ok, url} = RemoteFollow.subscribe_url("@alice@remote.example", @actor)

      refute url =~ "https://baudrate.test"
      assert url =~ "https%3A%2F%2Fbaudrate.test"
      assert String.ends_with?(url, "&x=1")
    end

    # The single most important refusal. Without the host check a hostile
    # server answers WebFinger with a template pointing anywhere, and this
    # site renders a link to it — on its own page, about to be clicked.
    test "refuses a template that is not on the domain the visitor typed" do
      stub_webfinger(webfinger(subscribe_link("https://evil.example/authorize?uri={uri}")))

      assert {:error, :template_off_domain} =
               RemoteFollow.subscribe_url("@alice@remote.example", @actor)
    end

    test "refuses a template that is not HTTPS" do
      stub_webfinger(webfinger(subscribe_link("http://remote.example/authorize?uri={uri}")))

      assert {:error, :template_not_https} =
               RemoteFollow.subscribe_url("@alice@remote.example", @actor)
    end

    test "refuses a scheme that is not http(s) at all" do
      stub_webfinger(webfinger(subscribe_link("javascript:alert({uri})")))

      assert {:error, :template_not_https} =
               RemoteFollow.subscribe_url("@alice@remote.example", @actor)
    end

    test "refuses a template with no {uri} placeholder" do
      stub_webfinger(webfinger(subscribe_link("https://remote.example/authorize")))

      assert {:error, :template_has_no_uri} =
               RemoteFollow.subscribe_url("@alice@remote.example", @actor)
    end

    test "refuses a document with no subscribe link" do
      links = [
        %{
          "rel" => "self",
          "type" => "application/activity+json",
          "href" => "https://remote.example/users/alice"
        }
      ]

      stub_webfinger(webfinger(links))

      assert {:error, :no_subscribe_template} =
               RemoteFollow.subscribe_url("@alice@remote.example", @actor)
    end

    test "refuses a subscribe link whose template is not a string" do
      links = [%{"rel" => "http://ostatus.org/schema/1.0/subscribe", "template" => 42}]
      stub_webfinger(webfinger(links))

      assert {:error, :no_subscribe_template} =
               RemoteFollow.subscribe_url("@alice@remote.example", @actor)
    end

    test "refuses a document that is not JSON" do
      stub_webfinger("not json at all")

      assert {:error, :lookup_failed} =
               RemoteFollow.subscribe_url("@alice@remote.example", @actor)
    end

    test "refuses when the lookup fails" do
      Req.Test.stub(HTTPClient, fn conn -> Plug.Conn.send_resp(conn, 500, "") end)

      assert {:error, :lookup_failed} =
               RemoteFollow.subscribe_url("@alice@remote.example", @actor)
    end

    # ADR 0030 decision 9: a block stops us reaching out, not only listening.
    # The flag lives in `Discovery.webfinger_document/3`; this is the test that
    # fails if it is dropped, because nothing downstream re-checks here.
    test "refuses a blocked domain without fetching it" do
      {:ok, _} = DomainBlocks.block_domain("remote.example", nil, %{reason: "acceptance test"})

      Req.Test.stub(HTTPClient, fn _conn ->
        flunk("a blocked domain must not be fetched")
      end)

      assert {:error, :lookup_failed} =
               RemoteFollow.subscribe_url("@alice@remote.example", @actor)
    end
  end
end
