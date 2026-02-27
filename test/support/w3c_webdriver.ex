defmodule BaudrateWeb.W3CWebDriver do
  @moduledoc """
  W3C-compliant WebDriver session creation for Wallaby.

  Wallaby 0.30's `WebdriverClient.create_session/2` sends legacy JSON Wire
  Protocol (`{"desiredCapabilities": {...}}`), but Selenium 4.x expects W3C
  format (`{"capabilities": {"alwaysMatch": {...}}}`). This module wraps the
  capabilities in W3C format and normalizes the response so Wallaby can
  proceed with the session.
  """

  @doc """
  Creates a WebDriver session using W3C capabilities format.

  Intended to be passed as `create_session_fn` in `Wallaby.start_session/1`.
  """
  def create_session(base_url, capabilities) do
    params = %{
      capabilities: %{
        alwaysMatch: capabilities
      }
    }

    case Wallaby.HTTPClient.request(:post, "#{base_url}session", params) do
      {:ok, response} ->
        # W3C nests sessionId under "value"; normalize to flat map for Wallaby
        case response do
          %{"value" => %{"sessionId" => _} = value} ->
            {:ok, value}

          %{"sessionId" => _} ->
            {:ok, response}

          _ ->
            {:error, "Unexpected session response: #{inspect(response)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
