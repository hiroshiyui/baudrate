defmodule Baudrate.Federation.LookupRemoteActorTest do
  use Baudrate.DataCase, async: false

  alias Baudrate.Federation
  alias Baudrate.Federation.{HTTPClient, KeyStore}

  describe "lookup_remote_actor/1" do
    test "returns error for invalid query format" do
      assert {:error, :invalid_query} = Federation.lookup_remote_actor("not-valid")
    end

    test "returns error for empty user part in @user@domain" do
      assert {:error, :invalid_query} = Federation.lookup_remote_actor("@domain.example")
    end

    test "returns error for empty domain part in @user@domain" do
      assert {:error, :invalid_query} = Federation.lookup_remote_actor("user@")
    end

    test "strips leading @ and performs WebFinger lookup" do
      {public_pem, _private_pem} = KeyStore.generate_keypair()

      actor_json =
        Jason.encode!(%{
          "id" => "https://remote.example/users/alice",
          "type" => "Person",
          "preferredUsername" => "alice",
          "inbox" => "https://remote.example/users/alice/inbox",
          "publicKey" => %{
            "id" => "https://remote.example/users/alice#main-key",
            "owner" => "https://remote.example/users/alice",
            "publicKeyPem" => public_pem
          }
        })

      webfinger_json =
        Jason.encode!(%{
          "subject" => "acct:alice@remote.example",
          "links" => [
            %{
              "rel" => "self",
              "type" => "application/activity+json",
              "href" => "https://remote.example/users/alice"
            }
          ]
        })

      Req.Test.stub(HTTPClient, fn conn ->
        cond do
          String.contains?(conn.request_path, ".well-known/webfinger") ->
            Plug.Conn.send_resp(conn, 200, webfinger_json)

          true ->
            Plug.Conn.send_resp(conn, 200, actor_json)
        end
      end)

      assert {:ok, actor} = Federation.lookup_remote_actor("@alice@remote.example")
      assert actor.username == "alice"
      assert actor.domain == "remote.example"
    end

    test "handles user@domain format (without leading @)" do
      {public_pem, _private_pem} = KeyStore.generate_keypair()

      actor_json =
        Jason.encode!(%{
          "id" => "https://other.example/users/bob",
          "type" => "Person",
          "preferredUsername" => "bob",
          "inbox" => "https://other.example/users/bob/inbox",
          "publicKey" => %{
            "id" => "https://other.example/users/bob#main-key",
            "owner" => "https://other.example/users/bob",
            "publicKeyPem" => public_pem
          }
        })

      webfinger_json =
        Jason.encode!(%{
          "subject" => "acct:bob@other.example",
          "links" => [
            %{
              "rel" => "self",
              "type" => "application/activity+json",
              "href" => "https://other.example/users/bob"
            }
          ]
        })

      Req.Test.stub(HTTPClient, fn conn ->
        cond do
          String.contains?(conn.request_path, ".well-known/webfinger") ->
            Plug.Conn.send_resp(conn, 200, webfinger_json)

          true ->
            Plug.Conn.send_resp(conn, 200, actor_json)
        end
      end)

      assert {:ok, actor} = Federation.lookup_remote_actor("bob@other.example")
      assert actor.username == "bob"
    end

    test "direct actor URL delegates to ActorResolver" do
      {public_pem, _private_pem} = KeyStore.generate_keypair()

      actor_json =
        Jason.encode!(%{
          "id" => "https://direct.example/users/charlie",
          "type" => "Person",
          "preferredUsername" => "charlie",
          "inbox" => "https://direct.example/users/charlie/inbox",
          "publicKey" => %{
            "id" => "https://direct.example/users/charlie#main-key",
            "owner" => "https://direct.example/users/charlie",
            "publicKeyPem" => public_pem
          }
        })

      Req.Test.stub(HTTPClient, fn conn ->
        Plug.Conn.send_resp(conn, 200, actor_json)
      end)

      assert {:ok, actor} = Federation.lookup_remote_actor("https://direct.example/users/charlie")
      assert actor.username == "charlie"
      assert actor.domain == "direct.example"
    end

    test "returns error when WebFinger has no self link" do
      webfinger_json =
        Jason.encode!(%{
          "subject" => "acct:noself@remote.example",
          "links" => [
            %{
              "rel" => "http://webfinger.net/rel/profile-page",
              "type" => "text/html",
              "href" => "https://remote.example/@noself"
            }
          ]
        })

      Req.Test.stub(HTTPClient, fn conn ->
        Plug.Conn.send_resp(conn, 200, webfinger_json)
      end)

      assert {:error, :no_self_link} = Federation.lookup_remote_actor("noself@remote.example")
    end

    test "returns error when WebFinger fetch fails" do
      Req.Test.stub(HTTPClient, fn conn ->
        Plug.Conn.send_resp(conn, 404, "Not Found")
      end)

      assert {:error, {:webfinger_failed, _}} =
               Federation.lookup_remote_actor("nobody@gone.example")
    end
  end
end
