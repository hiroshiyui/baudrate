defmodule Baudrate.DataPortability.DownloadNoncesTest do
  use ExUnit.Case, async: true

  alias Baudrate.DataPortability.DownloadNonces

  test "a nonce is consumed exactly once, and only by its user" do
    nonce = DownloadNonces.issue(1)

    assert :error = DownloadNonces.consume(nonce, 2)
    # A wrong-user attempt still consumes it: no retries for another purpose.
    assert :error = DownloadNonces.consume(nonce, 1)

    other = DownloadNonces.issue(1)
    assert :ok = DownloadNonces.consume(other, 1)
    assert :error = DownloadNonces.consume(other, 1)
  end

  test "expired and unknown nonces are refused" do
    :ets.insert(:data_export_download_nonces, {"old", 1, System.system_time(:second) - 1})

    assert :error = DownloadNonces.consume("old", 1)
    assert :error = DownloadNonces.consume("never-issued", 1)
    assert :error = DownloadNonces.consume(nil, 1)
  end
end
