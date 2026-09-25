defmodule Baudrate.Media.Warmer do
  @moduledoc """
  Pre-populates the media cache at ingest so the first viewer does not pay the
  fetch latency.

  Purely opportunistic — every failure is ignored, because
  `BaudrateWeb.MediaController` will fetch on demand anyway. This is why the
  proxy needs no backfill: warming is an optimisation, not a correctness
  requirement.

  Disabled in the test environment (`media_warm_enabled: false`), where
  federation tasks run synchronously and an incidental outbound fetch would make
  unrelated tests depend on the HTTP stub.
  """

  alias Baudrate.Media.Cache

  @max_urls 8

  @doc "Extracts remote `<img src>` from HTML and caches each in the background."
  @spec warm_html(String.t() | nil) :: :ok
  def warm_html(nil), do: :ok
  def warm_html(""), do: :ok

  def warm_html(html) when is_binary(html) do
    ~r/<img\b[^>]*?\bsrc="((?:https?:)?\/\/[^"]*)"/i
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&String.replace(&1, "&amp;", "&"))
    |> warm_urls()
  end

  def warm_html(_), do: :ok

  @doc "Caches each remote URL in the background, ignoring failures."
  @spec warm_urls([String.t()]) :: :ok
  def warm_urls(urls) when is_list(urls) do
    if enabled?() do
      urls
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.take(@max_urls)
      |> Enum.each(&warm_one/1)
    end

    :ok
  end

  def warm_urls(_), do: :ok

  defp enabled?, do: Application.get_env(:baudrate, :media_warm_enabled, true)

  defp warm_one(url) do
    Baudrate.Federation.schedule_federation_task(fn ->
      case Cache.cached_path(url) do
        {:ok, _path} -> :ok
        :miss -> Cache.fetch_and_store(url)
      end
    end)
  end
end
