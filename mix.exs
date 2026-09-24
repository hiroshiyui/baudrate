defmodule Baudrate.MixProject do
  use Mix.Project

  def project do
    [
      app: :baudrate,
      version: "1.45.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      releases: releases(),
      # Phase 8A. The PLT lives in priv/plts so CI can cache it by path;
      # .dialyzer_ignore.exs holds the reviewed baseline, and CI fails only on
      # a warning that is not in it.
      # References name the file but not the line: CI runs
      # `mix gettext.extract --check-up-to-date`, and with line numbers any
      # edit that moved a gettext call would fail it until someone re-extracted.
      gettext: [write_reference_line_numbers: false],
      # Phase 8A: CI merges each partition's coverage and publishes the report.
      # Report only — a threshold rewards tests written for the number.
      test_coverage: [summary: [threshold: 0], ignore_modules: [~r/^Inspect\./]],
      dialyzer: [
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts",
        plt_add_apps: [:mix, :ex_unit],
        ignore_warnings: ".dialyzer_ignore.exs",
        list_unused_filters: true
      ]
    ]
  end

  # Releases are built in CI and published (ADR 0036). The cookie written into
  # releases/COOKIE is therefore public, and fixed here rather than random so
  # every build of a commit is the same: rel/env.sh.eex refuses to join the
  # Erlang distribution with it, and the server provides its own
  # RELEASE_COOKIE.
  defp releases do
    [
      baudrate: [
        include_executables_for: [:unix],
        cookie: "public-not-a-secret-set-RELEASE_COOKIE"
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Baudrate.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.3"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.14"},
      {:postgrex, "~> 0.22"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.9.1"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:req, "~> 0.6"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:bandit, "~> 1.5"},
      {:bcrypt_elixir, "~> 3.0"},
      {:nimble_totp, "~> 1.0"},
      {:eqrcode, "~> 0.2.1"},
      {:hammer, "~> 7.0"},
      {:image, "~> 0.54"},
      {:mdex, "~> 0.13"},
      {:rustler, "~> 0.36", runtime: false},
      {:tz, "~> 0.28"},
      {:wallaby, "~> 0.30", runtime: false, only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.15", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:cbor, "~> 1.0"},
      {:wax_, "~> 0.7"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": [
        "compile",
        "tailwind baudrate",
        "esbuild baudrate",
        "esbuild cropper",
        "esbuild service_worker",
        "esbuild challenge_worker"
      ],
      "assets.deploy": [
        "tailwind baudrate --minify",
        "esbuild baudrate --minify",
        "esbuild cropper --minify",
        "esbuild service_worker --minify",
        "esbuild challenge_worker --minify",
        "phx.digest"
      ],
      lint: ["credo --strict"],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format --check-formatted",
        "lint",
        "test"
      ]
    ]
  end
end
