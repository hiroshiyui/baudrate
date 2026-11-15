defmodule Baudrate.Content.ComposerImageTest do
  @moduledoc """
  An image attached in a composer is charged **before** it is decoded
  (`Content.process_composer_image/2`): the interaction gate, then the hourly
  and daily upload buckets. The composers used to call the decoder directly,
  limited only by a count kept in the socket.

  The refusal cases pass a path that does not exist: had the decoder run, the
  answer would be a file error instead of the refusal.
  """

  use Baudrate.DataCase, async: true

  alias Baudrate.Auth.Sanction
  alias Baudrate.Content
  alias BaudrateWeb.RateLimiter.Sandbox

  import BaudrateWeb.ConnCase, only: [setup_user: 1]

  @missing "/nonexistent/composer-image-#{System.unique_integer([:positive])}.png"

  setup do
    tmp = Path.join(System.tmp_dir!(), "composer_image_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    {:ok, img} = Image.new(200, 200, color: [255, 100, 50])
    png = Path.join(tmp, "test.png")
    Image.write!(img, png)

    {:ok, png: png, user: setup_user("user")}
  end

  test "a member within the limits gets the image processed", %{user: user, png: png} do
    assert {:ok, %{filename: filename}} = Content.process_composer_image(user, png)
    assert is_binary(filename)
  end

  test "a suspended member is refused before the decode", %{user: user} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert!(%Sanction{
      user_id: user.id,
      kind: "suspend",
      reason: "test",
      issued_at: now,
      expires_at: DateTime.add(now, 3600, :second),
      inserted_at: now,
      updated_at: now
    })

    assert {:error, :account_suspended} =
             Content.process_composer_image(Repo.reload!(user), @missing)
  end

  test "a member past the hourly limit is refused before the decode", %{user: user} do
    Sandbox.set_fun(fn
      "composer_image:" <> _, _scale, limit -> {:deny, limit}
      _bucket, _scale, _limit -> {:allow, 1}
    end)

    assert {:error, :rate_limited} = Content.process_composer_image(user, @missing)
  end

  test "a member past the daily limit is refused before the decode", %{user: user} do
    Sandbox.set_fun(fn
      "composer_image_day:" <> _, _scale, limit -> {:deny, limit}
      _bucket, _scale, _limit -> {:allow, 1}
    end)

    assert {:error, :rate_limited} = Content.process_composer_image(user, @missing)
  end

  test "a new account has the smaller hourly limit", %{user: user} do
    test_pid = self()

    Sandbox.set_fun(fn bucket, _scale, limit ->
      send(test_pid, {:checked, bucket, limit})
      {:allow, 1}
    end)

    Content.process_composer_image(user, @missing)

    assert_received {:checked, "composer_image:" <> _, limit}
    assert limit == if(Baudrate.Auth.trusted?(user), do: 30, else: 5)
  end
end
