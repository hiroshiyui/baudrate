defmodule Baudrate.Logger.JSONFormatterInstallTest do
  @moduledoc """
  Reads the global `:default` Logger handler, so it runs synchronously.

  While any test is inside `capture_log/1`, ExUnit's capture server removes
  the `:default` handler and restores it afterwards. An async test reading
  that handler failed whenever another test was mid-capture; synchronous
  tests run after every async one, when no capture is in flight.
  """

  use ExUnit.Case, async: false

  alias Baudrate.Logger.JSONFormatter

  test "is not installed unless LOG_FORMAT=json was configured" do
    assert Application.get_env(:baudrate, :log_format) == nil
    assert :ok = JSONFormatter.install_if_configured()
    {:ok, %{formatter: {formatter, _}}} = :logger.get_handler_config(:default)
    refute formatter == JSONFormatter
  end
end
