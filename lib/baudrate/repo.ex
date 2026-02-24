defmodule Baudrate.Repo do
  @moduledoc """
  Ecto repository for Baudrate, backed by PostgreSQL.
  """

  use Ecto.Repo,
    otp_app: :baudrate,
    adapter: Ecto.Adapters.Postgres
end
