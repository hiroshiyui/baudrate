defmodule Baudrate.Repo do
  @moduledoc """
  Ecto repository for Baudrate, backed by PostgreSQL.
  """

  use Ecto.Repo,
    otp_app: :baudrate,
    adapter: Ecto.Adapters.Postgres

  @doc """
  Escapes SQL LIKE wildcard characters (`%`, `_`, `\\`) in a string.

  Use this when building ILIKE/LIKE patterns from user input to prevent
  wildcard injection.

  ## Examples

      iex> Baudrate.Repo.sanitize_like("100%")
      "100\\\\%"

      iex> Baudrate.Repo.sanitize_like("user_name")
      "user\\\\_name"
  """
  @spec sanitize_like(String.t()) :: String.t()
  def sanitize_like(str) when is_binary(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end
end
