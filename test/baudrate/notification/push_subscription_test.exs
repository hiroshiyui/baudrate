defmodule Baudrate.Notification.PushSubscriptionTest do
  use Baudrate.DataCase, async: true

  alias Baudrate.Notification.PushSubscription

  setup do
    Baudrate.Setup.seed_roles_and_permissions()
    user = create_user("push_sub")
    %{user: user}
  end

  describe "changeset/2" do
    test "valid changeset with all required fields", %{user: user} do
      attrs = %{
        endpoint: "https://push.example.com/send/abc123",
        p256dh: :crypto.strong_rand_bytes(65),
        auth: :crypto.strong_rand_bytes(16),
        user_id: user.id
      }

      changeset = PushSubscription.changeset(%PushSubscription{}, attrs)
      assert changeset.valid?
    end

    test "valid changeset with optional user_agent", %{user: user} do
      attrs = %{
        endpoint: "https://push.example.com/send/abc123",
        p256dh: :crypto.strong_rand_bytes(65),
        auth: :crypto.strong_rand_bytes(16),
        user_agent: "Mozilla/5.0",
        user_id: user.id
      }

      changeset = PushSubscription.changeset(%PushSubscription{}, attrs)
      assert changeset.valid?
    end

    test "requires endpoint", %{user: user} do
      attrs = %{
        p256dh: :crypto.strong_rand_bytes(65),
        auth: :crypto.strong_rand_bytes(16),
        user_id: user.id
      }

      changeset = PushSubscription.changeset(%PushSubscription{}, attrs)
      assert %{endpoint: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires p256dh", %{user: user} do
      attrs = %{
        endpoint: "https://push.example.com/send/abc123",
        auth: :crypto.strong_rand_bytes(16),
        user_id: user.id
      }

      changeset = PushSubscription.changeset(%PushSubscription{}, attrs)
      assert %{p256dh: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires auth", %{user: user} do
      attrs = %{
        endpoint: "https://push.example.com/send/abc123",
        p256dh: :crypto.strong_rand_bytes(65),
        user_id: user.id
      }

      changeset = PushSubscription.changeset(%PushSubscription{}, attrs)
      assert %{auth: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires user_id" do
      attrs = %{
        endpoint: "https://push.example.com/send/abc123",
        p256dh: :crypto.strong_rand_bytes(65),
        auth: :crypto.strong_rand_bytes(16)
      }

      changeset = PushSubscription.changeset(%PushSubscription{}, attrs)
      assert %{user_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates endpoint max length", %{user: user} do
      attrs = %{
        endpoint: "https://push.example.com/" <> String.duplicate("a", 2049),
        p256dh: :crypto.strong_rand_bytes(65),
        auth: :crypto.strong_rand_bytes(16),
        user_id: user.id
      }

      changeset = PushSubscription.changeset(%PushSubscription{}, attrs)
      errors = errors_on(changeset)
      assert Enum.any?(errors[:endpoint] || [], &(&1 =~ "at most"))
    end

    test "rejects non-HTTPS endpoint (http://)", %{user: user} do
      attrs = %{
        endpoint: "http://push.example.com/send/abc123",
        p256dh: :crypto.strong_rand_bytes(65),
        auth: :crypto.strong_rand_bytes(16),
        user_id: user.id
      }

      changeset = PushSubscription.changeset(%PushSubscription{}, attrs)
      assert %{endpoint: ["must be a valid HTTPS URL"]} = errors_on(changeset)
    end

    test "rejects non-URL endpoint", %{user: user} do
      attrs = %{
        endpoint: "not-a-url",
        p256dh: :crypto.strong_rand_bytes(65),
        auth: :crypto.strong_rand_bytes(16),
        user_id: user.id
      }

      changeset = PushSubscription.changeset(%PushSubscription{}, attrs)
      assert %{endpoint: ["must be a valid HTTPS URL"]} = errors_on(changeset)
    end

    test "rejects file:// scheme endpoint", %{user: user} do
      attrs = %{
        endpoint: "file:///etc/passwd",
        p256dh: :crypto.strong_rand_bytes(65),
        auth: :crypto.strong_rand_bytes(16),
        user_id: user.id
      }

      changeset = PushSubscription.changeset(%PushSubscription{}, attrs)
      assert %{endpoint: ["must be a valid HTTPS URL"]} = errors_on(changeset)
    end

    test "enforces unique endpoint constraint", %{user: user} do
      attrs = %{
        endpoint: "https://push.example.com/send/unique123",
        p256dh: :crypto.strong_rand_bytes(65),
        auth: :crypto.strong_rand_bytes(16),
        user_id: user.id
      }

      {:ok, _sub} =
        %PushSubscription{}
        |> PushSubscription.changeset(attrs)
        |> Repo.insert()

      {:error, changeset} =
        %PushSubscription{}
        |> PushSubscription.changeset(attrs)
        |> Repo.insert()

      assert %{endpoint: ["has already been taken"]} = errors_on(changeset)
    end
  end

  defp create_user(prefix) do
    role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == "user"))
    uid = System.unique_integer([:positive])

    {:ok, user} =
      %Baudrate.Setup.User{}
      |> Baudrate.Setup.User.registration_changeset(%{
        "username" => "#{prefix}_#{uid}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    user
  end
end
