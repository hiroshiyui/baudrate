defmodule BaudrateWeb.SeleniumServer do
  @moduledoc """
  Auto-starts Selenium Server for browser tests.

  Multi-partition safe: the first partition to arrive starts the server,
  others detect it via health check.
  """

  @selenium_jar "selenium-server-4.27.0.jar"
  @health_url ~c"http://localhost:4444/status"
  @poll_interval 500
  # A cold JVM on a CI runner can take well over 15 s to bring the standalone
  # server up; locally it is ready in a few seconds.
  @timeout 60_000

  # The CI image keeps Selenium and GeckoDriver in /opt/selenium
  # (BAUDRATE_SELENIUM_DIR); locally they come from `mix selenium.setup`.
  defp selenium_dir do
    System.get_env("BAUDRATE_SELENIUM_DIR") || Path.expand("../../tmp/selenium", __DIR__)
  end

  @doc """
  Ensures Selenium Server is running. Starts it if not already up.
  """
  def ensure_running do
    if server_ready?() do
      :ok
    else
      start_server()
      wait_for_ready(0)
    end
  end

  defp server_ready? do
    :inets.start()
    :ssl.start()

    case :httpc.request(:get, {@health_url, []}, [{:timeout, 2000}], []) do
      {:ok, {{_, 200, _}, _, body}} ->
        body_str = to_string(body)
        String.contains?(body_str, "\"ready\"") and String.contains?(body_str, "true")

      _ ->
        false
    end
  end

  defp start_server do
    jar_path = Path.join(selenium_dir(), @selenium_jar)

    unless File.exists?(jar_path) do
      raise """
      Selenium Server JAR not found at #{jar_path}.
      Run `mix selenium.setup` to download it.
      """
    end

    # Set PATH to include geckodriver location
    current_path = System.get_env("PATH", "")
    env_path = ~c"#{selenium_dir()}:#{current_path}"

    log_path = Path.join(selenium_dir(), "server.log")

    Port.open(
      {:spawn_executable, System.find_executable("java")},
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-jar", jar_path, "standalone", "--port", "4444", "--log", log_path],
        env: [{~c"PATH", env_path}],
        cd: to_charlist(selenium_dir())
      ]
    )

    IO.puts("Starting Selenium Server (log: #{log_path})...")
  end

  defp wait_for_ready(elapsed) when elapsed >= @timeout do
    raise "Selenium Server did not become ready within #{@timeout}ms"
  end

  defp wait_for_ready(elapsed) do
    Process.sleep(@poll_interval)

    if server_ready?() do
      IO.puts("Selenium Server is ready.")
      :ok
    else
      wait_for_ready(elapsed + @poll_interval)
    end
  end
end
