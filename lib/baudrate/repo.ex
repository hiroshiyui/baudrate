defmodule Baudrate.Repo do
  use Ecto.Repo,
    otp_app: :baudrate,
    adapter: Ecto.Adapters.Postgres
end
