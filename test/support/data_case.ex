defmodule Baudrate.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Baudrate.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Baudrate.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Baudrate.DataCase
    end
  end

  setup tags do
    Baudrate.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Baudrate.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  @doc """
  Returns the current TOTP code for `secret`.

  A code for the previous 30-second period is still accepted (ADR 0024), so a
  code generated just before a period boundary and verified just after it
  works. No waiting is needed.
  """
  def totp_code(secret), do: NimbleTOTP.verification_code(secret)

  @doc """
  Forgets the TOTP period last accepted for `user` (a struct or id), so the
  current code can be used again.

  Codes are consumed on use (ADR 0024). A test that authenticates twice
  within the same 30 seconds, where a real user would be minutes or days
  apart (requesting an export, then downloading it), calls this between the
  two instead of waiting for the next period.
  """
  def forget_totp_use(%{id: id}), do: forget_totp_use(id)

  def forget_totp_use(user_id) when is_integer(user_id) do
    import Ecto.Query, only: [from: 2]

    Baudrate.Repo.update_all(
      from(u in Baudrate.Setup.User, where: u.id == ^user_id),
      set: [totp_last_used_step: nil]
    )

    :ok
  end
end
