defmodule Baudrate.Logger.JSONFormatter do
  @moduledoc """
  An optional JSON log format: one JSON object per line, for log shippers and
  `jq`. Off by default; set `LOG_FORMAT=json` (Phase 2D).

      {"time":"2026-09-17T10:15:02.114Z","level":"info","message":"federation.delivery_ok: inbox=…","request_id":"F…"}

  A `:logger` formatter (see Erlang's `logger` formatter callbacks), installed on the
  default handler at boot by `install_if_configured/0`. It is written here
  rather than taken from a library to keep the dependency list short.

  ## What it writes

    * `time` (UTC, milliseconds), `level` and `message`, formatted and truncated
      the way the text format does (`Logger.Formatter.format_event/2`).
    * Only the metadata in the allow-list: `request_id`, and `module` and
      `function` from the call site. Anything else a library puts in metadata
      stays out, so nothing is logged that the text format would not show.

  ## What it must never do

  A formatter that raises gets its handler removed, which silently ends all
  logging. Invalid UTF-8 is replaced rather than passed to the encoder, and any
  other failure falls back to a plain line saying the event could not be
  formatted. Newlines inside a message are escaped by JSON, so a message cannot
  forge a second log line.
  """

  require Logger

  @truncate 8096
  @replacement "�"

  @doc """
  Installs this formatter on the default handler when `:log_format` is
  `:json`. Returns `:ok` either way.
  """
  @spec install_if_configured() :: :ok
  def install_if_configured do
    with :json <- Application.get_env(:baudrate, :log_format),
         {:error, reason} <-
           :logger.update_handler_config(:default, :formatter, {__MODULE__, %{}}) do
      # A missing default handler must not stop the node from booting.
      Logger.warning("LOG_FORMAT=json could not be applied: #{inspect(reason)}")
    end

    :ok
  end

  @doc false
  def check_config(config) when is_map(config), do: :ok
  def check_config(_), do: {:error, :invalid_config}

  @doc "Formats one `:logger` event as a JSON line."
  @spec format(:logger.log_event(), map()) :: iodata()
  def format(%{level: level, meta: meta} = event, _config) do
    fields =
      %{
        "time" => format_time(meta),
        "level" => Atom.to_string(level),
        "message" => event |> Logger.Formatter.format_event(@truncate) |> to_valid_string()
      }
      |> put_metadata(meta)

    [Jason.encode_to_iodata!(fields), ?\n]
  rescue
    _ -> [fallback_line(), ?\n]
  catch
    # `rescue` covers exceptions raised in the body, not a `throw` or `exit`
    # from encoding someone else's term. `:logger` removes a handler that
    # fails, which would end all logging — the one thing this must never do.
    _kind, _value -> [fallback_line(), ?\n]
  end

  # A log event without `:level` or `:meta` (a hand-rolled `:logger.log/2`, or
  # a future OTP change) would not match the clause above, and a head-match
  # failure happens before `rescue` can catch anything.
  def format(_event, _config), do: [fallback_line(), ?\n]

  defp fallback_line do
    "{\"level\":\"error\",\"message\":\"log event could not be formatted\"}"
  end

  defp put_metadata(fields, meta) do
    fields
    |> maybe_put("request_id", meta[:request_id])
    |> put_call_site(meta[:mfa])
  end

  defp put_call_site(fields, {module, function, arity})
       when is_atom(module) and is_atom(function) and is_integer(arity) do
    fields
    |> Map.put("module", inspect(module))
    |> Map.put("function", "#{function}/#{arity}")
  end

  defp put_call_site(fields, _), do: fields

  defp maybe_put(fields, _key, nil), do: fields
  defp maybe_put(fields, key, value), do: Map.put(fields, key, to_valid_string(value))

  defp format_time(%{time: time}) when is_integer(time) do
    time
    |> DateTime.from_unix!(:microsecond)
    |> DateTime.truncate(:millisecond)
    |> DateTime.to_iso8601()
  end

  defp format_time(_meta) do
    DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
  end

  defp to_valid_string(value) when is_binary(value),
    do: String.replace_invalid(value, @replacement)

  defp to_valid_string(value) when is_list(value) do
    value |> Logger.Formatter.prune() |> IO.chardata_to_string() |> to_valid_string()
  end

  defp to_valid_string(value), do: value |> inspect() |> to_valid_string()
end
