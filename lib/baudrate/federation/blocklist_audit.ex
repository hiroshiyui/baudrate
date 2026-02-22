defmodule Baudrate.Federation.BlocklistAudit do
  @moduledoc """
  Audits the local domain blocklist against an external known-bad-actor list.

  Fetches a remote blocklist (JSON array or CSV/newline-separated) and compares
  it to the local `ap_domain_blocklist` setting. Returns a diff showing which
  domains are missing from the local blocklist and which are extra.

  Supports common blocklist formats:
    * JSON array of domain strings
    * Newline-separated domains (one per line)
    * CSV format (Mastodon export: `domain,severity,reason`)
    * Lines starting with `#` are treated as comments
  """

  require Logger

  alias Baudrate.Federation.HTTPClient
  alias Baudrate.Setup

  @doc """
  Runs the blocklist audit.

  Fetches the external blocklist configured in `ap_blocklist_audit_url`,
  compares it to the local `ap_domain_blocklist`, and returns a diff.

  Returns `{:ok, audit_result}` or `{:error, reason}`.
  """
  def audit do
    with {:ok, url} <- get_audit_url(),
         {:ok, external_domains} <- fetch_external_list(url) do
      local_blocked = get_local_blocklist()

      missing = MapSet.difference(external_domains, local_blocked)
      extra = MapSet.difference(local_blocked, external_domains)

      {:ok,
       %{
         external_count: MapSet.size(external_domains),
         local_count: MapSet.size(local_blocked),
         missing: MapSet.to_list(missing) |> Enum.sort(),
         extra: MapSet.to_list(extra) |> Enum.sort(),
         overlap: MapSet.intersection(external_domains, local_blocked) |> MapSet.size()
       }}
    end
  end

  defp get_audit_url do
    case Setup.get_setting("ap_blocklist_audit_url") do
      nil -> {:error, :no_audit_url}
      "" -> {:error, :no_audit_url}
      url -> {:ok, url}
    end
  end

  defp fetch_external_list(url) do
    case HTTPClient.get(url) do
      {:ok, %{body: body}} -> parse_list(body)
      {:error, reason} -> {:error, {:fetch_failed, reason}}
    end
  end

  @doc false
  def parse_list(body) do
    case Jason.decode(body) do
      {:ok, list} when is_list(list) ->
        domains =
          list
          |> Enum.filter(&is_binary/1)
          |> Enum.map(&(String.downcase(&1) |> String.trim()))
          |> Enum.reject(&(&1 == ""))
          |> MapSet.new()

        {:ok, domains}

      _ ->
        # CSV/newline format
        domains =
          body
          |> String.split(~r/[\r\n]+/, trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(String.starts_with?(&1, "#") or &1 == ""))
          |> Enum.map(&extract_domain/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(&String.downcase/1)
          |> MapSet.new()

        {:ok, domains}
    end
  end

  # Handle CSV rows like "domain,severity,reason" (Mastodon export format)
  defp extract_domain(line) do
    line |> String.split(",", parts: 2) |> List.first() |> String.trim()
  end

  @doc false
  def get_local_blocklist do
    (Setup.get_setting("ap_domain_blocklist") || "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end
end
