defmodule Baudrate.Release do
  @moduledoc """
  Release tasks for running migrations and rollbacks in production.

  Used by the `bin/migrate` overlay script or via `eval`:

      bin/baudrate eval "Baudrate.Release.migrate"
      bin/baudrate eval "Baudrate.Release.rollback(Baudrate.Repo, 20240101000000)"
  """

  @app :baudrate

  @doc """
  Runs all pending Ecto migrations.
  """
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc """
  Rolls back the given repo to the specified migration version.
  """
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
