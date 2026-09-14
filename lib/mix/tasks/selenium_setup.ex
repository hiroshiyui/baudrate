defmodule Mix.Tasks.Selenium.Setup do
  @moduledoc """
  Installs Selenium Server and GeckoDriver for browser testing.

      mix selenium.setup

  Installs into `tmp/selenium/`:
  - Selenium Server 4.49.0 JAR, from the Selenium GitHub release
  - GeckoDriver 0.37.1, built from its crates.io source crate (needs `cargo`)

  Existing files are kept when they match these versions; an older GeckoDriver
  is rebuilt.

  Every download is checked against a pinned SHA-256 before it is used, so a
  tampered or truncated file (on a developer machine or in CI) is refused
  instead of being executed. Bump the checksum together with the version, and
  the matching `ARG`s in `ci/image/Dockerfile`.

  GeckoDriver is built from source because its 0.37.x release binaries are
  signed only by a Mozilla subkey revoked on 2026-08-06 as compromised. The
  crate is published through a separate channel and ships its `Cargo.lock`;
  `cargo build --locked` checks every dependency against it.
  """

  use Mix.Task

  @selenium_version "4.49.0"
  @geckodriver_version "0.37.1"
  @selenium_sha256 "8221cb7bf687b8ca13c31c2bca9fb8cc12e9d4c808baff670c66cb0e450ceb35"
  @geckodriver_crate_sha256 "79f38cf1541aaf57f6f7eb270f691bcb702485a95dbaaefe740141a8ea46f0ef"
  @dest_dir "tmp/selenium"

  @selenium_url "https://github.com/SeleniumHQ/selenium/releases/download/selenium-#{@selenium_version}/selenium-server-#{@selenium_version}.jar"
  @geckodriver_crate_url "https://static.crates.io/crates/geckodriver/geckodriver-#{@geckodriver_version}.crate"

  @shortdoc "Installs Selenium Server and GeckoDriver for browser testing"

  @doc """
  File name of the pinned Selenium Server JAR, shared with
  `BaudrateWeb.SeleniumServer` so the version lives in one place.
  """
  def selenium_jar_name, do: "selenium-server-#{@selenium_version}.jar"

  @impl Mix.Task
  def run(_args) do
    Application.ensure_all_started(:req)

    File.mkdir_p!(@dest_dir)

    download_if_missing(
      Path.join(@dest_dir, selenium_jar_name()),
      @selenium_url,
      @selenium_sha256,
      "Selenium Server #{@selenium_version}"
    )

    install_geckodriver(Path.join(@dest_dir, "geckodriver"))

    Mix.shell().info("Selenium setup complete. Files in #{@dest_dir}/")
  end

  defp download_if_missing(dest, url, sha256, label) do
    if File.exists?(dest) do
      Mix.shell().info("#{label} already exists at #{dest}")
    else
      Mix.shell().info("Downloading #{label}...")
      download_file(url, dest)
      verify_sha256!(dest, sha256)
      Mix.shell().info("Downloaded #{label} to #{dest}")
    end
  end

  defp install_geckodriver(dest) do
    if installed_geckodriver_version(dest) == @geckodriver_version do
      Mix.shell().info("GeckoDriver #{@geckodriver_version} already exists at #{dest}")
    else
      build_geckodriver(dest)
    end
  end

  defp installed_geckodriver_version(path) do
    with true <- File.exists?(path),
         {output, 0} <- System.cmd(Path.expand(path), ["--version"], stderr_to_stdout: true),
         [_, version] <- Regex.run(~r/\Ageckodriver (\S+)/, output) do
      version
    else
      _ -> nil
    end
  end

  defp build_geckodriver(dest) do
    cargo =
      System.find_executable("cargo") ||
        Mix.raise(
          "GeckoDriver #{@geckodriver_version} is built from source and needs cargo (the Rust toolchain) on PATH"
        )

    # Built outside the repository: GeckoDriver's build script embeds the
    # commit of the nearest enclosing .git/.hg checkout in `--version`.
    build_root =
      Path.join(System.tmp_dir!(), "baudrate-geckodriver-#{System.unique_integer([:positive])}")

    File.mkdir_p!(build_root)

    try do
      build_geckodriver_in(build_root, cargo, dest)
    after
      File.rm_rf!(build_root)
    end
  end

  defp build_geckodriver_in(build_root, cargo, dest) do
    crate = Path.join(build_root, "geckodriver-#{@geckodriver_version}.crate")
    source_dir = Path.join(build_root, "geckodriver-#{@geckodriver_version}")
    target_dir = Path.join(build_root, "target")

    Mix.shell().info("Downloading the GeckoDriver #{@geckodriver_version} source crate...")
    download_file(@geckodriver_crate_url, crate)
    verify_sha256!(crate, @geckodriver_crate_sha256)
    {_, 0} = System.cmd("tar", ["xzf", crate, "-C", build_root])

    Mix.shell().info("Building GeckoDriver #{@geckodriver_version} (cargo build --locked)...")

    args = [
      "build",
      "--release",
      "--locked",
      "--manifest-path",
      Path.join(source_dir, "Cargo.toml"),
      "--target-dir",
      target_dir
    ]

    case System.cmd(cargo, args, into: IO.stream(), stderr_to_stdout: true) do
      {_, 0} -> :ok
      {_, status} -> Mix.raise("Building GeckoDriver failed (cargo exited with #{status})")
    end

    File.cp!(Path.join([target_dir, "release", "geckodriver"]), dest)
    File.chmod!(dest, 0o755)
    Mix.shell().info("GeckoDriver #{@geckodriver_version} installed at #{dest}")
  end

  defp verify_sha256!(path, expected) do
    actual =
      path
      |> File.stream!(65_536)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    if actual != expected do
      File.rm(path)
      Mix.raise("Checksum mismatch for #{path}: expected #{expected}, got #{actual}")
    end
  end

  defp download_file(url, dest) do
    case Req.get(url, into: File.stream!(dest)) do
      {:ok, %Req.Response{status: 200}} ->
        :ok

      {:ok, %Req.Response{status: status}} ->
        File.rm(dest)
        Mix.raise("Failed to download #{url}: HTTP #{status}")

      {:error, reason} ->
        File.rm(dest)
        Mix.raise("Failed to download #{url}: #{inspect(reason)}")
    end
  end
end
