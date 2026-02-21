defmodule Baudrate.Federation.RemoteActorTest do
  use Baudrate.DataCase, async: true

  alias Baudrate.Federation.RemoteActor

  @valid_attrs %{
    ap_id: "https://remote.example/users/alice",
    username: "alice",
    domain: "remote.example",
    public_key_pem: "-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----",
    inbox: "https://remote.example/users/alice/inbox",
    actor_type: "Person",
    fetched_at: ~U[2026-01-01 00:00:00Z]
  }

  describe "changeset/2" do
    test "valid changeset with all required fields" do
      changeset = RemoteActor.changeset(%RemoteActor{}, @valid_attrs)
      assert changeset.valid?
    end

    test "valid changeset with optional fields" do
      attrs =
        Map.merge(@valid_attrs, %{
          display_name: "Alice",
          avatar_url: "https://remote.example/avatars/alice.png",
          shared_inbox: "https://remote.example/inbox"
        })

      changeset = RemoteActor.changeset(%RemoteActor{}, attrs)
      assert changeset.valid?
    end

    test "missing ap_id is invalid" do
      changeset = RemoteActor.changeset(%RemoteActor{}, Map.delete(@valid_attrs, :ap_id))
      refute changeset.valid?
      assert %{ap_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "missing username is invalid" do
      changeset = RemoteActor.changeset(%RemoteActor{}, Map.delete(@valid_attrs, :username))
      refute changeset.valid?
      assert %{username: ["can't be blank"]} = errors_on(changeset)
    end

    test "missing domain is invalid" do
      changeset = RemoteActor.changeset(%RemoteActor{}, Map.delete(@valid_attrs, :domain))
      refute changeset.valid?
      assert %{domain: ["can't be blank"]} = errors_on(changeset)
    end

    test "missing public_key_pem is invalid" do
      changeset = RemoteActor.changeset(%RemoteActor{}, Map.delete(@valid_attrs, :public_key_pem))
      refute changeset.valid?
      assert %{public_key_pem: ["can't be blank"]} = errors_on(changeset)
    end

    test "missing inbox is invalid" do
      changeset = RemoteActor.changeset(%RemoteActor{}, Map.delete(@valid_attrs, :inbox))
      refute changeset.valid?
      assert %{inbox: ["can't be blank"]} = errors_on(changeset)
    end

    test "missing actor_type uses default and is valid" do
      changeset = RemoteActor.changeset(%RemoteActor{}, Map.delete(@valid_attrs, :actor_type))

      # actor_type has a schema default of "Person", but cast doesn't use schema defaults for missing keys.
      # Since actor_type is in required fields but not provided, it should be invalid.
      # Actually the schema default only applies to %RemoteActor{}, and the changeset validates required.
      # The cast will not set it if not in attrs, and the schema default is already set on the struct.
      assert changeset.valid?
    end

    test "missing fetched_at is invalid" do
      changeset = RemoteActor.changeset(%RemoteActor{}, Map.delete(@valid_attrs, :fetched_at))
      refute changeset.valid?
      assert %{fetched_at: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid actor_type is rejected" do
      changeset =
        RemoteActor.changeset(%RemoteActor{}, Map.put(@valid_attrs, :actor_type, "Robot"))

      refute changeset.valid?
      assert %{actor_type: ["is invalid"]} = errors_on(changeset)
    end

    test "valid actor_types are accepted" do
      for type <- ~w(Person Group Organization Application Service) do
        changeset =
          RemoteActor.changeset(%RemoteActor{}, Map.put(@valid_attrs, :actor_type, type))

        assert changeset.valid?, "Expected #{type} to be valid"
      end
    end

    test "unique constraint on ap_id" do
      {:ok, _} =
        %RemoteActor{}
        |> RemoteActor.changeset(@valid_attrs)
        |> Repo.insert()

      {:error, changeset} =
        %RemoteActor{}
        |> RemoteActor.changeset(@valid_attrs)
        |> Repo.insert()

      assert %{ap_id: ["has already been taken"]} = errors_on(changeset)
    end
  end
end
