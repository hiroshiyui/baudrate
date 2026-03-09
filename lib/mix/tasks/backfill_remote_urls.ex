defmodule Mix.Tasks.BackfillRemoteUrls do
  @moduledoc """
  Backfills missing `url` fields on remote articles and comments by
  re-fetching their AP objects from the originating instances.

      mix backfill_remote_urls

  For each remote article/comment that has an `ap_id` but no `url`,
  performs a signed HTTP GET to retrieve the AP JSON and extracts
  the `url` field. Requests are rate-limited with a 1-second delay
  between fetches to avoid overwhelming remote servers.

  ## Options

    * `--dry-run` — show what would be fetched without making changes
  """

  use Mix.Task

  require Logger

  @shortdoc "Backfill missing url fields on remote articles and comments"

  @impl Mix.Task
  def run(args) do
    dry_run = "--dry-run" in args

    Mix.Task.run("app.start")

    if dry_run do
      Mix.shell().info("Dry run mode — no changes will be made.\n")
    end

    backfill_articles(dry_run)
    backfill_comments(dry_run)
  end

  defp backfill_articles(dry_run) do
    import Ecto.Query
    alias Baudrate.Repo

    articles =
      from(a in Baudrate.Content.Article,
        where:
          not is_nil(a.ap_id) and
            not is_nil(a.remote_actor_id) and
            is_nil(a.url),
        select: %{id: a.id, ap_id: a.ap_id}
      )
      |> Repo.all()

    Mix.shell().info("Remote articles missing url: #{length(articles)}")

    Enum.each(articles, fn %{id: id, ap_id: ap_id} ->
      case fetch_url(ap_id, dry_run) do
        {:ok, url} ->
          Mix.shell().info("  Article ##{id}: #{url}")

          unless dry_run do
            from(a in Baudrate.Content.Article, where: a.id == ^id)
            |> Repo.update_all(set: [url: url])
          end

        {:skip, reason} ->
          Mix.shell().info("  Article ##{id}: skipped (#{reason})")
      end

      unless dry_run, do: Process.sleep(1000)
    end)

    Mix.shell().info("")
  end

  defp backfill_comments(dry_run) do
    import Ecto.Query
    alias Baudrate.Repo

    comments =
      from(c in Baudrate.Content.Comment,
        where:
          not is_nil(c.ap_id) and
            not is_nil(c.remote_actor_id) and
            is_nil(c.url),
        select: %{id: c.id, ap_id: c.ap_id}
      )
      |> Repo.all()

    Mix.shell().info("Remote comments missing url: #{length(comments)}")

    Enum.each(comments, fn %{id: id, ap_id: ap_id} ->
      case fetch_url(ap_id, dry_run) do
        {:ok, url} ->
          Mix.shell().info("  Comment ##{id}: #{url}")

          unless dry_run do
            from(c in Baudrate.Content.Comment, where: c.id == ^id)
            |> Repo.update_all(set: [url: url])
          end

        {:skip, reason} ->
          Mix.shell().info("  Comment ##{id}: skipped (#{reason})")
      end

      unless dry_run, do: Process.sleep(1000)
    end)
  end

  defp fetch_url(ap_id, true = _dry_run) do
    {:skip, "dry run — would fetch #{ap_id}"}
  end

  defp fetch_url(ap_id, _dry_run) do
    alias Baudrate.Federation.{HTTPClient, KeyStore}
    alias Baudrate.Setup

    with {:ok, _} <- KeyStore.ensure_site_keypair(),
         private_pem when is_binary(private_pem) <- Setup.get_setting("ap_site_private_key"),
         {:ok, private_pem} <- Baudrate.Federation.KeyVault.decrypt(private_pem) do
      site_uri = Baudrate.Federation.actor_uri(:site, nil)
      key_id = "#{site_uri}#main-key"

      case HTTPClient.signed_get(ap_id, private_pem, key_id) do
        {:ok, %{body: body}} ->
          case Jason.decode(body) do
            {:ok, object} ->
              url = extract_url(object)

              if url do
                {:ok, url}
              else
                {:skip, "no url in AP object"}
              end

            {:error, _} ->
              {:skip, "invalid JSON"}
          end

        {:error, reason} ->
          {:skip, "fetch failed: #{inspect(reason)}"}
      end
    else
      _ -> {:skip, "no site keypair configured"}
    end
  end

  # Replicates the extract_url logic from InboxHandler
  defp extract_url(%{"url" => url}) when is_binary(url), do: url

  defp extract_url(%{"url" => [first | _] = urls}) when is_list(urls) do
    html_link =
      Enum.find(urls, fn
        %{"mediaType" => mt, "href" => _} -> mt == "text/html"
        _ -> false
      end)

    case html_link do
      %{"href" => href} -> href
      nil when is_binary(first) -> first
      nil -> Map.get(List.first(urls) || %{}, "href")
    end
  end

  defp extract_url(_), do: nil
end
