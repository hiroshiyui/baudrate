defmodule Baudrate.DataPortability.Archive do
  @moduledoc """
  Builds a data export archive at download time (ADR 0023 §7, §14–§18).

  No archive is ever stored. `build/2` writes a ZIP into a private temporary
  directory, the caller streams it, then calls `cleanup/1`. Leftovers from a
  crash are removed by `sweep_temp/0` (from `Auth.SessionCleaner` at boot and
  hourly). Under systemd, `PrivateTmp=true` also gives the service its own
  `/tmp`, which is wiped on restart.

  ## Guarantees

    * **One build at a time, instance-wide.** The build runs inside a
      transaction that first takes `pg_try_advisory_xact_lock/1`. A busy slot
      returns `{:error, :busy}` immediately (no queueing). The lock is released
      on commit, rollback, or a dropped connection, so a crashed build cannot
      wedge the slot.
    * **Bounded.** A deadline (`:timeout_ms`, default 120 s) is checked between
      steps, and each query is capped with `SET LOCAL statement_timeout`. A
      size cap (`:max_bytes`, default 500 MB) is checked while staging. A
      breach deletes everything written and returns
      `{:error, :timeout | :too_large}`.
    * **Private files.** Staging directory `0700`, archive `0600`, both under
      `System.tmp_dir!/0`, never under `priv/static` or `shared/uploads`.
    * **Safe entry names.** Built from record ids and fixed names only, never
      titles or client filenames. JSON only: no CSV (formula injection) and no
      HTML (script execution when opened locally).
    * **Content** comes from `Baudrate.DataPortability.Collector` (allow-list
      serializers, visibility rules), and **media paths** from
      `Baudrate.DataPortability.Files` (confinement).
  """

  require Logger
  use Gettext, backend: BaudrateWeb.Gettext

  alias Baudrate.Repo
  alias Baudrate.DataPortability.Collector
  alias Baudrate.Setup.User

  # Arbitrary, stable key for the instance-wide build slot.
  @lock_key 0x42_61_75_64_45_78_70
  @default_timeout_ms 120_000
  @default_max_bytes 500 * 1024 * 1024
  @temp_prefix "baudrate-export-"
  @stale_temp_seconds 3600

  @doc """
  Builds the archive for `user`. Options:

    * `:base_url` — instance base URL for URIs (required)
    * `:timeout_ms` — build deadline (default #{@default_timeout_ms})
    * `:max_bytes` — size cap for staged content (default #{@default_max_bytes})
    * `:generated_at` — timestamp written to README (default now)

  Returns `{:ok, %{path: zip_path, size: bytes, dir: temp_dir}}`, or
  `{:error, :busy | :timeout | :too_large | term}`. On success the caller must
  call `cleanup/1` after sending the file.
  """
  @spec build(User.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def build(%User{} = user, opts) do
    base_url = Keyword.fetch!(opts, :base_url)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    result =
      Repo.transaction(
        fn ->
          case Repo.query!("SELECT pg_try_advisory_xact_lock($1)", [@lock_key]) do
            %{rows: [[true]]} ->
              Repo.query!("SELECT set_config('statement_timeout', $1, true)", [
                Integer.to_string(max(timeout_ms, 1))
              ])

              case do_build(user, base_url, deadline, max_bytes, opts) do
                {:ok, info} -> info
                {:error, reason} -> Repo.rollback(reason)
              end

            _ ->
              Repo.rollback(:busy)
          end
        end,
        timeout: timeout_ms + 5_000
      )

    case result do
      {:ok, info} ->
        Logger.info("data_export.archive_built: user_id=#{user.id} bytes=#{info.size}")
        {:ok, info}

      {:error, reason} ->
        Logger.warning("data_export.archive_failed: user_id=#{user.id} reason=#{inspect(reason)}")
        {:error, reason}
    end
  rescue
    # `SET LOCAL statement_timeout` cancels an overlong query.
    error in Postgrex.Error ->
      Logger.error("data_export.archive_failed: user_id=#{user.id} error=#{inspect(error)}")

      case error do
        %Postgrex.Error{postgres: %{code: :query_canceled}} -> {:error, :timeout}
        _ -> {:error, :database}
      end

    error in DBConnection.ConnectionError ->
      Logger.error("data_export.archive_failed: user_id=#{user.id} error=#{inspect(error)}")
      {:error, :database}
  end

  @doc false
  # Exposed for tests that hold the slot from a separate connection.
  def lock_key, do: @lock_key

  @doc "Deletes a built archive and its staging directory."
  @spec cleanup(map()) :: :ok
  # sobelow_skip ["Traversal.FileModule"]
  def cleanup(%{dir: dir}) do
    File.rm_rf(dir)
    :ok
  end

  @doc """
  Removes export temp directories older than an hour (crash leftovers).
  Returns the number removed.
  """
  @spec sweep_temp() :: non_neg_integer()
  # sobelow_skip ["Traversal.FileModule"]
  def sweep_temp do
    tmp = System.tmp_dir!()
    cutoff = System.os_time(:second) - @stale_temp_seconds

    tmp
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, @temp_prefix))
    |> Enum.map(&Path.join(tmp, &1))
    |> Enum.filter(fn path ->
      case File.lstat(path, time: :posix) do
        {:ok, %File.Stat{type: :directory, mtime: mtime}} -> mtime < cutoff
        _ -> false
      end
    end)
    |> Enum.map(&File.rm_rf/1)
    |> length()
  rescue
    _ -> 0
  end

  # ---------------------------------------------------------------------------

  # sobelow_skip ["Traversal.FileModule"]
  defp do_build(user, base_url, deadline, max_bytes, opts) do
    user = Repo.preload(user, :role, force: true)
    dir = make_private_dir()

    try do
      with :ok <- check_deadline(deadline),
           {documents, media} = Collector.collect(user, base_url),
           :ok <- check_deadline(deadline),
           staging = Path.join(dir, "export"),
           :ok <- File.mkdir(staging),
           {:ok, names, bytes} <- stage_documents(staging, documents, user, opts),
           :ok <- check_size(bytes, max_bytes),
           {:ok, names, _bytes} <- stage_media(staging, media, names, bytes, max_bytes, deadline),
           :ok <- check_deadline(deadline),
           {:ok, zip} <- zip(dir, staging, names) do
        File.chmod!(zip, 0o600)
        File.rm_rf(staging)
        {:ok, %{path: zip, size: File.stat!(zip).size, dir: dir}}
      else
        {:error, _} = error ->
          File.rm_rf(dir)
          error
      end
    rescue
      error ->
        File.rm_rf(dir)
        reraise error, __STACKTRACE__
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp make_private_dir do
    name = @temp_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    dir = Path.join(System.tmp_dir!(), name)
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    dir
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp stage_documents(staging, documents, user, opts) do
    readme = readme(user, Keyword.get(opts, :generated_at, DateTime.utc_now()))

    entries =
      [{"README.txt", readme}] ++
        Enum.map(Enum.sort(documents), fn {name, data} ->
          {name, Jason.encode_to_iodata!(data, pretty: true)}
        end)

    Enum.reduce(entries, {:ok, [], 0}, fn {name, content}, {:ok, names, bytes} ->
      File.write!(Path.join(staging, name), content)
      {:ok, [name | names], bytes + IO.iodata_length(content)}
    end)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp stage_media(staging, media, names, bytes, max_bytes, deadline) do
    Enum.reduce_while(media, {:ok, names, bytes}, fn {entry, source}, {:ok, names, bytes} ->
      with :ok <- check_deadline(deadline),
           {:ok, %File.Stat{size: size}} <- File.stat(source),
           :ok <- check_size(bytes + size, max_bytes) do
        target = Path.join(staging, entry)
        File.mkdir_p!(Path.dirname(target))
        File.cp!(source, target)
        {:cont, {:ok, [entry | names], bytes + size}}
      else
        {:error, reason} when reason in [:timeout, :too_large] -> {:halt, {:error, reason}}
        # A file that vanished between collection and staging is skipped.
        _ -> {:cont, {:ok, names, bytes}}
      end
    end)
  end

  defp zip(dir, staging, names) do
    zip_path = Path.join(dir, "export.zip")
    files = names |> Enum.reverse() |> Enum.map(&String.to_charlist/1)

    case :zip.create(String.to_charlist(zip_path), files,
           cwd: String.to_charlist(staging),
           uncompress: [~c".webp"]
         ) do
      {:ok, _} -> {:ok, zip_path}
      {:error, reason} -> {:error, {:zip, reason}}
    end
  end

  defp check_deadline(deadline) do
    if System.monotonic_time(:millisecond) <= deadline, do: :ok, else: {:error, :timeout}
  end

  defp check_size(bytes, max_bytes) do
    if bytes <= max_bytes, do: :ok, else: {:error, :too_large}
  end

  defp readme(user, generated_at) do
    locale = BaudrateWeb.Locale.resolve_from_preferences(user.preferred_locales) || "en"

    Gettext.with_locale(BaudrateWeb.Gettext, locale, fn ->
      [
        gettext("Baudrate data export for %{username}", username: user.username),
        "\n",
        gettext("Generated at: %{time}", time: DateTime.to_iso8601(generated_at)),
        "\n\n",
        gettext("Included:"),
        "\n",
        gettext(
          "- profile.json: your profile, settings, whether two-factor authentication is on, and your security key labels"
        ),
        "\n",
        gettext(
          "- articles.json, comments.json, timeline_replies.json: what you wrote and can still see, including your own article revisions and polls"
        ),
        "\n",
        gettext(
          "- interactions.json: your likes, boosts, poll votes and bookmarks (targets as links only)"
        ),
        "\n",
        gettext("- relationships.json: who you follow, your followers, blocks and mutes"),
        "\n",
        gettext("- messages.json: direct messages you sent, and who you sent them to"),
        "\n",
        gettext("- invites.json: invite codes you created (active codes are not included)"),
        "\n",
        gettext("- media/: your avatar and the images you uploaded"),
        "\n\n",
        gettext("Not included:"),
        "\n",
        gettext(
          "- passwords, two-factor secrets, recovery codes, security key material, session tokens and IP addresses"
        ),
        "\n",
        gettext(
          "- messages written by other people, notifications, moderation reports and logs, reading history"
        ),
        "\n",
        gettext("- content removed by moderators, and content in boards you can no longer view"),
        "\n"
      ]
    end)
  end
end
