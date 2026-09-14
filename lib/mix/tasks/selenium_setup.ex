defmodule Mix.Tasks.Selenium.Setup do
  @moduledoc """
  Downloads Selenium Server and GeckoDriver for browser testing.

      mix selenium.setup

  Downloads:
  - Selenium Server 4.27.0 JAR
  - GeckoDriver 0.36.0 (linux64)

  Files are placed in `tmp/selenium/`. Skips download if files already exist.

  Every download is checked against a pinned SHA-256 before it is used, so a
  tampered or truncated file (on a developer machine or in CI) is refused
  instead of being executed. Bump the checksum together with the version.
  """

  use Mix.Task

  @selenium_version "4.27.0"
  @geckodriver_version "0.36.0"
  @selenium_sha256 "5481ca09814fc0ec8c2b8ff07b8574a467f49f0c285107b1525325d535408d6a"
  @geckodriver_tarball_sha256 "0bde38707eb0a686a20c6bd50f4adcc7d60d4f73c60eb83ee9e0db8f65823e04"
  @dest_dir "tmp/selenium"

  @selenium_url "https://github.com/SeleniumHQ/selenium/releases/download/selenium-#{@selenium_version}/selenium-server-#{@selenium_version}.jar"
  @geckodriver_url "https://github.com/mozilla/geckodriver/releases/download/v#{@geckodriver_version}/geckodriver-v#{@geckodriver_version}-linux64.tar.gz"

  @shortdoc "Downloads Selenium Server and GeckoDriver for browser testing"

  @impl Mix.Task
  def run(_args) do
    Application.ensure_all_started(:req)

    File.mkdir_p!(@dest_dir)

    selenium_jar = Path.join(@dest_dir, "selenium-server-#{@selenium_version}.jar")
    geckodriver_bin = Path.join(@dest_dir, "geckodriver")

    download_if_missing(
      selenium_jar,
      @selenium_url,
      @selenium_sha256,
      "Selenium Server #{@selenium_version}"
    )

    download_geckodriver_if_missing(geckodriver_bin)

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

  defp download_geckodriver_if_missing(dest) do
    if File.exists?(dest) do
      Mix.shell().info("GeckoDriver already exists at #{dest}")
    else
      tarball = Path.join(@dest_dir, "geckodriver.tar.gz")
      Mix.shell().info("Downloading GeckoDriver #{@geckodriver_version}...")
      download_file(@geckodriver_url, tarball)
      verify_sha256!(tarball, @geckodriver_tarball_sha256)

      Mix.shell().info("Extracting GeckoDriver...")
      {_, 0} = System.cmd("tar", ["xzf", tarball, "-C", @dest_dir])
      File.rm(tarball)
      File.chmod!(dest, 0o755)
      Mix.shell().info("GeckoDriver extracted to #{dest}")
    end
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
