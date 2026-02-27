# Patch: Override Wallaby.HTTPClient for W3C WebDriver (Selenium 4) compatibility.
#
# Fixes for Wallaby 0.30 → Selenium 4 (W3C WebDriver):
# 1. Send "{}" instead of "" for empty POST bodies (clear, click).
# 2. Transform set_value from JSON Wire Protocol (%{value: [text]}) to
#    W3C format (%{text: text}) for element/value endpoints.
#
# Loaded at runtime via Code.compile_file in test_helper.exs to avoid
# compile-time module redefinition warnings.
defmodule Wallaby.HTTPClient do
  @moduledoc false

  alias Wallaby.Query

  @type method :: :post | :get | :delete
  @type url :: String.t()
  @type params :: map | String.t()
  @type request_opts :: {:encode_json, boolean}
  @type response :: map
  @type web_driver_error_reason :: :stale_reference | :invalid_selector | :unexpected_alert

  @status_obscured 13
  @max_jitter 50

  @spec request(method, url, params, [request_opts]) ::
          {:ok, response}
          | {:error, web_driver_error_reason | Jason.DecodeError.t() | String.t()}
          | no_return
  def request(method, url, params \\ %{}, opts \\ [])

  # FIX: Send "{}" instead of "" for empty POST bodies (W3C WebDriver compliance)
  def request(method, url, params, _opts) when map_size(params) == 0 do
    make_request(method, url, "{}")
  end

  def request(method, url, params, [{:encode_json, false} | _]) do
    make_request(method, url, params)
  end

  def request(method, url, params, _opts) do
    url = w3c_url(url)
    params = w3c_transform(url, params)
    make_request(method, url, Jason.encode!(params))
  end

  # FIX: Rewrite legacy JSON Wire Protocol URLs to W3C WebDriver URLs.
  defp w3c_url(url) do
    url
    |> String.replace(~r"/execute$", "/execute/sync")
    |> String.replace("/execute_async", "/execute/async")
    |> String.replace("/window/current/size", "/window/rect")
  end

  # FIX: Transform JSON Wire Protocol set_value format to W3C format.
  # Wallaby sends %{value: [text]} but W3C expects %{text: text}.
  defp w3c_transform(url, %{value: [text]} = _params) when is_binary(text) do
    if String.ends_with?(url, "/value"), do: %{text: text}, else: %{value: [text]}
  end

  defp w3c_transform(_url, params), do: params

  defp make_request(method, url, body), do: make_request(method, url, body, 0, [])

  defp make_request(_, _, _, 5, retry_reasons) do
    ["Wallaby had an internal issue with HTTPoison:" | retry_reasons]
    |> Enum.uniq()
    |> Enum.join("\n")
    |> raise
  end

  defp make_request(method, url, body, retry_count, retry_reasons) do
    method
    |> HTTPoison.request(url, body, headers(), request_opts())
    |> handle_response()
    |> case do
      {:error, :httpoison, error} ->
        :timer.sleep(jitter())
        make_request(method, url, body, retry_count + 1, [inspect(error) | retry_reasons])

      result ->
        result
    end
  end

  defp handle_response(resp) do
    case resp do
      {:error, %HTTPoison.Error{} = error} ->
        {:error, :httpoison, error}

      {:ok, %HTTPoison.Response{status_code: 204}} ->
        {:ok, %{"value" => nil}}

      {:ok, %HTTPoison.Response{body: body}} ->
        with {:ok, decoded} <- Jason.decode(body),
             {:ok, response} <- check_status(decoded) do
          check_for_response_errors(response)
        end
    end
  end

  defp check_status(response) do
    case Map.get(response, "status") do
      @status_obscured ->
        message = get_in(response, ["value", "message"])
        {:error, message}

      _ ->
        {:ok, response}
    end
  end

  def check_for_response_errors(response) do
    response = coerce_json_message(response)

    case Map.get(response, "value") do
      %{"class" => "org.openqa.selenium.StaleElementReferenceException"} ->
        {:error, :stale_reference}

      %{"message" => "Stale element reference" <> _} ->
        {:error, :stale_reference}

      %{"message" => "stale element reference" <> _} ->
        {:error, :stale_reference}

      %{
        "message" =>
          "An element command failed because the referenced element is no longer available" <> _
      } ->
        {:error, :stale_reference}

      %{"message" => %{"value" => "An invalid or illegal selector was specified"}} ->
        {:error, :invalid_selector}

      %{"message" => "invalid selector" <> _} ->
        {:error, :invalid_selector}

      %{"class" => "org.openqa.selenium.InvalidSelectorException"} ->
        {:error, :invalid_selector}

      %{"class" => "org.openqa.selenium.InvalidElementStateException"} ->
        {:error, :invalid_selector}

      %{"message" => "unexpected alert" <> _} ->
        {:error, :unexpected_alert}

      # W3C WebDriver error format: "error" field contains the error type
      %{"error" => "stale element reference"} ->
        {:error, :stale_reference}

      %{"error" => "invalid selector"} ->
        {:error, :invalid_selector}

      %{"error" => "unexpected alert open"} ->
        {:error, :unexpected_alert}

      %{"error" => _, "message" => message} ->
        raise message

      _ ->
        {:ok, response}
    end
  end

  defp request_opts do
    Application.get_env(:wallaby, :hackney_options, hackney: [pool: :wallaby_pool])
  end

  defp headers do
    [{"Accept", "application/json"}, {"Content-Type", "application/json;charset=UTF-8"}]
  end

  @spec to_params(Query.compiled()) :: map
  def to_params({:xpath, xpath}) do
    %{using: "xpath", value: xpath}
  end

  def to_params({:css, css}) do
    %{using: "css selector", value: css}
  end

  defp jitter, do: :rand.uniform(@max_jitter)

  defp coerce_json_message(%{"value" => %{"message" => message} = value} = response) do
    value =
      with %{"payload" => payload, "type" => type} <-
             Regex.named_captures(~r/(?<type>.*): (?<payload>{.*})\n.*/, message),
           {:ok, message} <- Jason.decode(payload) do
        %{
          "message" => message,
          "type" => type
        }
      else
        _ ->
          value
      end

    put_in(response["value"], value)
  end

  defp coerce_json_message(response) do
    response
  end
end
