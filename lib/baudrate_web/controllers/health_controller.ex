defmodule BaudrateWeb.HealthController do
  @moduledoc """
  Health check endpoint for load balancers and monitoring.

  Returns 200 with `{"status":"ok"}` when the application and database are
  healthy, or 503 with `{"status":"error"}` when the database is unreachable.
  """

  use BaudrateWeb, :controller

  def check(conn, _params) do
    case Ecto.Adapters.SQL.query(Baudrate.Repo, "SELECT 1") do
      {:ok, _result} ->
        conn
        |> put_status(200)
        |> json(%{status: "ok"})

      {:error, _reason} ->
        conn
        |> put_status(503)
        |> json(%{status: "error"})
    end
  end
end
