defmodule Baudrate.Auth.TermsAcceptanceTest do
  @moduledoc """
  Recording that a member accepted the terms, and which version.

  Before this, `terms_accepted` was virtual: the checkbox was validated and the
  answer discarded, so editing the terms silently changed what everyone had
  agreed to.
  """
  use Baudrate.DataCase, async: false

  alias Baudrate.Auth
  alias Baudrate.Setup

  setup do
    Setup.seed_roles_and_permissions()
    Setup.set_setting("registration_mode", "open")
    :ok
  end

  defp register(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    Auth.register_user(
      Map.merge(
        %{
          "username" => "member#{n}",
          "password" => "Password123!x",
          "password_confirmation" => "Password123!x",
          "terms_accepted" => "true"
        },
        attrs
      )
    )
  end

  describe "the published version" do
    test "starts at zero, so a fresh instance asks nobody to re-accept" do
      assert Setup.current_terms_version() == 0
    end

    test "moves only when an admin publishes" do
      Setup.update_eua("Some terms.")
      assert Setup.current_terms_version() == 0

      assert {:ok, 1} = Setup.publish_terms_version()
      assert Setup.current_terms_version() == 1
    end

    test "reads an unreadable value as zero rather than pausing the instance" do
      Setup.set_setting("eua_version", "not a number")

      assert Setup.current_terms_version() == 0
    end
  end

  describe "registration" do
    test "records when the member accepted, and what" do
      {:ok, _} = Setup.publish_terms_version()
      {:ok, _} = Setup.publish_terms_version()

      {:ok, user, _codes} = register()

      assert user.terms_version == 2
      assert %DateTime{} = user.terms_accepted_at
    end

    test "still refuses an unchecked box" do
      assert {:error, changeset} = register(%{"terms_accepted" => "false"})
      assert errors_on(changeset)[:terms_accepted]
    end

    test "records nothing when the registration fails" do
      before = Repo.aggregate(Setup.User, :count)

      assert {:error, _} = register(%{"terms_accepted" => "false"})

      assert Repo.aggregate(Setup.User, :count) == before
    end

    test "cannot be told which version it accepted" do
      # The registration params are an allow-list. A member who could set this
      # would accept a version that does not exist yet and never be asked again.
      {:ok, _} = Setup.publish_terms_version()

      {:ok, user, _codes} = register(%{"terms_version" => "999"})

      assert user.terms_version == 1
    end
  end
end
