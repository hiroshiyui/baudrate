defmodule Mix.Tasks.Selenium.Setup do
  @moduledoc """
  Downloads Selenium Server and GeckoDriver for browser testing.

      mix selenium.setup

  Downloads:
  - Selenium Server 4.27.0 JAR
  - GeckoDriver 0.36.0 (linux64)

  Files are placed in `tmp/selenium/`. Skips download if files already exist.
  """

  use Mix.Task

  @selenium_version "4.27.0"
  @geckodriver_version "0.36.0"
  @dest_dir "tmp/selenium"

  @selenium_url "https://github.com/SeleniumHQ/selenium/releases/download/selenium-#{@selenium_version}/selenium-server-#{@selenium_version}.jar"
  @geckodriver_url "https://github.com/mozilla/geckodriver/releases/download/v#{@geckodriver_version}/geckodriver-v#{@geckodriver_version}-linux64.tar.gz"

  @shortdoc "Downloads Selenium Server and GeckoDriver for browser testing"

  @impl Mix.Task
  def run(_args) do
    :inets.start()
    :ssl.start()

    File.mkdir_p!(@dest_dir)

    selenium_jar = Path.join(@dest_dir, "selenium-server-#{@selenium_version}.jar")
    geckodriver_bin = Path.join(@dest_dir, "geckodriver")

    download_if_missing(selenium_jar, @selenium_url, "Selenium Server #{@selenium_version}")
    download_geckodriver_if_missing(geckodriver_bin)

    Mix.shell().info("Selenium setup complete. Files in #{@dest_dir}/")
  end

  defp download_if_missing(dest, url, label) do
    if File.exists?(dest) do
      Mix.shell().info("#{label} already exists at #{dest}")
    else
      Mix.shell().info("Downloading #{label}...")
      download_file(url, dest)
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

      Mix.shell().info("Extracting GeckoDriver...")
      {_, 0} = System.cmd("tar", ["xzf", tarball, "-C", @dest_dir])
      File.rm(tarball)
      File.chmod!(dest, 0o755)
      Mix.shell().info("GeckoDriver extracted to #{dest}")
    end
  end

  defp download_file(url, dest) do
    ssl_opts = [
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    ]

    case :httpc.request(:get, {String.to_charlist(url), []}, ssl_opts ++ [autoredirect: true],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _, body}} ->
        File.write!(dest, body)

      {:ok, {{_, status, _}, headers, _}} when status in [301, 302, 303, 307, 308] ->
        location =
          headers
          |> Enum.find(fn {k, _} -> String.downcase(to_string(k)) == "location" end)
          |> elem(1)
          |> to_string()

        download_file(location, dest)

      {:ok, {{_, status, _}, _, _}} ->
        Mix.raise("Failed to download #{url}: HTTP #{status}")

      {:error, reason} ->
        Mix.raise("Failed to download #{url}: #{inspect(reason)}")
    end
  end
end
