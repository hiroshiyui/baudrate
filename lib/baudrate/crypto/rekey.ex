defmodule Baudrate.Crypto.Rekey do
  @moduledoc """
  Re-encrypts stored secrets under the current key, and counts what is not
  there yet (ADR 0038).

  `Baudrate.Release.rotate_keys/1` is how an operator runs this;
  `Baudrate.Health`'s `encryption_keys` check reads `usage/0`.

  ## What it covers

  | Stored value | Key class | Re-encryptable |
  |---|---|---|
  | `users.totp_secret` | `:auth` | yes |
  | `users.ap_private_key_encrypted` | `:signing` | yes |
  | `boards.ap_private_key_encrypted` | `:signing` | yes |
  | `settings.ap_site_private_key_encrypted` | `:signing` | yes |
  | `settings.vapid_private_key_encrypted` | `:signing` | yes |
  | `recovery_codes.code_hash` | `:auth` | **no** — counted only |

  A recovery code is a one-way hash of something only the member has, so it
  can move to a new key only by being regenerated. Until then its row keeps
  the id of the key that hashed it, and that key must stay configured: the
  count is what tells an operator whether dropping it would take away
  someone's way back into their account.

  ## How it runs

  Rows are taken in batches by id and skipped when they already carry the
  current key, so the work left is derived from the data rather than from a
  bookmark: the task resumes by being run again, and running it twice changes
  nothing.

  Each write is conditional on the value the row still holding what was read
  (`UPDATE … WHERE column = <old value>`). The documented way to run this is
  against the live node, where a member may enrol TOTP or an admin may rotate
  an actor key mid-run; that row now holds a newer secret under the current
  key, and must not be overwritten with the older plaintext.

  A value that cannot be decrypted — a key that is gone, or something that was
  never ciphertext — is counted and logged, never written and never raised.
  """

  import Ecto.Query

  require Logger

  alias Baudrate.Auth.{RecoveryCode, TotpVault}
  alias Baudrate.Content.Board
  alias Baudrate.Crypto.{Keyring, Vault}
  alias Baudrate.Federation.KeyVault
  alias Baudrate.Notification.VapidVault
  alias Baudrate.Repo
  alias Baudrate.Setup
  alias Baudrate.Setup.User

  @default_batch 200

  @type target :: String.t()
  @type usage :: %{target() => %{Keyring.id() => non_neg_integer()}}
  @type result :: %{
          rekeyed: non_neg_integer(),
          undecryptable: non_neg_integer(),
          skipped_concurrent: non_neg_integer(),
          remaining: usage()
        }

  @doc """
  How many stored values sit under each key, per place they are stored.

  The keys of the outer map are `"table.column"`; the inner keys are key ids,
  with `"legacy"` for a value still protected by the `secret_key_base`
  fallback.
  """
  @spec usage() :: usage()
  def usage do
    columns =
      Map.new(column_targets(), fn target ->
        counts =
          target
          |> blob_query()
          |> Repo.all()
          |> Enum.frequencies_by(fn %{blob: blob} -> id_of(target, blob) end)

        {target.name, counts}
      end)

    settings =
      Map.new(setting_targets(), fn target ->
        counts =
          case Setup.get_setting(target.setting) do
            nil -> %{}
            value -> %{id_of(target, value) => 1}
          end

        {target.name, counts}
      end)

    recovery =
      RecoveryCode
      |> group_by([rc], rc.key_id)
      |> select([rc], {rc.key_id, count(rc.id)})
      |> Repo.all()
      |> Map.new()

    columns
    |> Map.merge(settings)
    |> Map.put("recovery_codes.code_hash", recovery)
  end

  @doc """
  The purpose each place is protected by, so a count can be judged against the
  right class of key.
  """
  @spec purposes_by_target() :: %{target() => Keyring.purpose()}
  def purposes_by_target do
    (column_targets() ++ setting_targets())
    |> Map.new(fn target -> {target.name, target.purpose} end)
    |> Map.put("recovery_codes.code_hash", :recovery_code)
  end

  @doc """
  Key ids that stored values reference but configuration does not have.

  Those values cannot be read at all, which is what the health report calls a
  failure. `"legacy"` is never unknown: the fallback is always derivable while
  `secret_key_base` is set.
  """
  @spec unknown_key_ids() :: [Keyring.id()]
  def unknown_key_ids, do: unknown_key_ids(usage())

  @doc "As `unknown_key_ids/0`, for a census already read."
  @spec unknown_key_ids(usage()) :: [Keyring.id()]
  def unknown_key_ids(usage) do
    purposes = purposes_by_target()

    for {target, counts} <- usage,
        {id, count} <- counts,
        count > 0,
        unknown?(Map.fetch!(purposes, target), id),
        uniq: true,
        do: id
  end

  @doc """
  Re-encrypts everything that is not on the current key.

  Options:

    * `:dry_run` — report what would be written, write nothing (default `false`)
    * `:only` — key classes to work on (default both)
    * `:batch` — rows read at a time (default #{@default_batch})
    * `:after_read` — for tests: called with the target name and row id after a
      value is read and before it is written, to stand in for a member
      enrolling TOTP mid-run
  """
  @spec run(keyword()) :: result()
  def run(opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)
    classes = Keyword.get(opts, :only, Keyring.classes())
    batch = Keyword.get(opts, :batch, @default_batch)
    after_read = Keyword.get(opts, :after_read, fn _target, _id -> :ok end)

    if dry_run, do: Logger.info("rotate_keys: dry run — nothing will be written")

    for class <- classes do
      {id, _key} = Keyring.current(class_purpose(class))
      Logger.info("rotate_keys: #{class} current=#{id}")
    end

    totals =
      Enum.reduce(targets_for(classes), blank(), fn target, acc ->
        add(acc, rekey_target(target, dry_run, batch, after_read))
      end)

    report_recovery_codes(classes)

    Logger.info(
      "rotate_keys: complete — rekeyed=#{totals.rekeyed} " <>
        "undecryptable=#{totals.undecryptable} skipped_concurrent=#{totals.skipped_concurrent}"
    )

    remaining = usage()
    log_usage(remaining)

    Map.put(totals, :remaining, remaining)
  end

  # --- targets ---

  # A user's TOTP secret and their actor key live in the same row but belong to
  # different classes, which is the point of separating them.
  defp column_targets do
    [
      %{
        name: "users.totp_secret",
        class: :auth,
        purpose: :totp,
        schema: User,
        field: :totp_secret,
        encode: :raw,
        vault: :totp
      },
      %{
        name: "users.ap_private_key_encrypted",
        class: :signing,
        purpose: :federation,
        schema: User,
        field: :ap_private_key_encrypted,
        encode: :raw,
        vault: :user_key
      },
      %{
        name: "boards.ap_private_key_encrypted",
        class: :signing,
        purpose: :federation,
        schema: Board,
        field: :ap_private_key_encrypted,
        encode: :raw,
        vault: :board_key
      }
    ]
  end

  defp setting_targets do
    [
      %{
        name: "settings.#{KeyVault.site_setting()}",
        class: :signing,
        purpose: :federation,
        setting: KeyVault.site_setting(),
        encode: :base64,
        vault: :site_key
      },
      %{
        name: "settings.#{VapidVault.setting()}",
        class: :signing,
        purpose: :vapid,
        setting: VapidVault.setting(),
        encode: :base64,
        vault: :vapid
      }
    ]
  end

  defp targets_for(classes) do
    Enum.filter(column_targets() ++ setting_targets(), &(&1.class in classes))
  end

  defp class_purpose(:auth), do: :totp
  defp class_purpose(:signing), do: :federation

  # --- re-encryption ---

  defp rekey_target(%{setting: setting} = target, dry_run, _batch, _after_read) do
    case Setup.get_setting(setting) do
      nil ->
        blank()

      value ->
        {id, _key} = Keyring.current(target.purpose)

        if id_of(target, value) == id do
          blank()
        else
          rekey_setting(target, value, id, dry_run)
        end
    end
  end

  defp rekey_target(target, dry_run, batch, after_read) do
    {current_id, _key} = Keyring.current(target.purpose)

    rekey_rows(target, current_id, dry_run, batch, after_read, 0, blank())
  end

  defp rekey_rows(target, current_id, dry_run, batch, after_read, after_id, acc) do
    rows =
      target
      |> blob_query()
      |> where([r], r.id > ^after_id)
      |> order_by([r], asc: r.id)
      |> limit(^batch)
      |> Repo.all()

    if rows == [] do
      acc
    else
      acc =
        rows
        |> Enum.reject(&(id_of(target, &1.blob) == current_id))
        |> Enum.reduce(acc, fn row, acc ->
          add(acc, rekey_row(target, row, current_id, dry_run, after_read))
        end)

      last = rows |> List.last() |> Map.fetch!(:id)
      rekey_rows(target, current_id, dry_run, batch, after_read, last, acc)
    end
  end

  defp rekey_row(target, %{id: id, blob: blob}, current_id, dry_run, after_read) do
    case decrypt_blob(target, id, blob) do
      {:ok, plaintext} ->
        after_read.(target.name, id)

        if dry_run do
          Logger.info(
            "rotate_keys: [dry] #{target.name} ##{id} #{id_of(target, blob)} -> #{current_id}"
          )

          %{blank() | rekeyed: 1}
        else
          write_row(target, id, blob, encrypt(target, id, plaintext), current_id)
        end

      :error ->
        Logger.warning(
          "rotate_keys: #{target.name} ##{id} could not be decrypted " <>
            "(key #{id_of(target, blob)}) — left unchanged"
        )

        %{blank() | undecryptable: 1}
    end
  end

  defp write_row(target, id, old_blob, new_blob, current_id) do
    query =
      from(r in target.schema,
        where: r.id == ^id and field(r, ^target.field) == ^old_blob
      )

    case Repo.update_all(query, set: [{target.field, new_blob}]) do
      {1, _} ->
        Logger.info("rotate_keys: #{target.name} ##{id} -> #{current_id}")
        %{blank() | rekeyed: 1}

      {0, _} ->
        # Someone wrote a newer secret while this ran; it is already under the
        # current key, and the older plaintext must not replace it.
        Logger.info("rotate_keys: #{target.name} ##{id} changed while running — left alone")
        %{blank() | skipped_concurrent: 1}
    end
  end

  defp rekey_setting(target, value, current_id, dry_run) do
    with {:ok, blob} <- Base.decode64(value),
         {:ok, plaintext} <- decrypt_blob(target, nil, blob) do
      if dry_run do
        Logger.info("rotate_keys: [dry] #{target.name} #{id_of(target, value)} -> #{current_id}")

        %{blank() | rekeyed: 1}
      else
        encoded = Base.encode64(encrypt(target, nil, plaintext))
        {:ok, _} = Setup.set_setting(target.setting, encoded)
        Setup.SettingsCache.refresh()
        Logger.info("rotate_keys: #{target.name} -> #{current_id}")
        %{blank() | rekeyed: 1}
      end
    else
      _ ->
        Logger.warning("rotate_keys: #{target.name} could not be decrypted — left unchanged")

        %{blank() | undecryptable: 1}
    end
  end

  defp report_recovery_codes(classes) do
    if :auth in classes do
      {current_id, _key} = Keyring.current(:recovery_code)

      counts =
        RecoveryCode
        |> group_by([rc], rc.key_id)
        |> select([rc], {rc.key_id, count(rc.id)})
        |> Repo.all()
        |> Enum.map(fn {id, count} -> "#{id}=#{count}" end)
        |> Enum.join(" ")

      if counts != "" do
        Logger.info(
          "rotate_keys: recovery_codes.code_hash cannot be re-keyed " <>
            "(current=#{current_id}) — #{counts}. A key listed here must stay " <>
            "configured until its members regenerate their codes."
        )
      end
    end
  end

  defp log_usage(usage) do
    summary =
      usage
      |> Enum.reject(fn {_target, counts} -> counts == %{} end)
      |> Enum.sort()
      |> Enum.map_join("; ", fn {target, counts} ->
        inner = Enum.map_join(counts, " ", fn {id, count} -> "#{id}=#{count}" end)
        "#{target} #{inner}"
      end)

    if summary != "", do: Logger.info("rotate_keys: remaining — #{summary}")
  end

  # --- vault plumbing ---

  defp blob_query(%{schema: schema, field: field}) do
    from(r in schema,
      where: not is_nil(field(r, ^field)),
      select: %{id: r.id, blob: field(r, ^field)}
    )
  end

  defp decrypt_blob(%{vault: :totp}, id, blob), do: TotpVault.decrypt(blob, %User{id: id})
  defp decrypt_blob(%{vault: :user_key}, id, blob), do: KeyVault.decrypt(blob, %User{id: id})
  defp decrypt_blob(%{vault: :board_key}, id, blob), do: KeyVault.decrypt(blob, %Board{id: id})
  defp decrypt_blob(%{vault: :site_key}, _id, blob), do: KeyVault.decrypt(blob, :site)
  defp decrypt_blob(%{vault: :vapid}, _id, blob), do: VapidVault.decrypt(blob)

  defp encrypt(%{vault: :totp}, id, plaintext), do: TotpVault.encrypt(plaintext, %User{id: id})
  defp encrypt(%{vault: :user_key}, id, plaintext), do: KeyVault.encrypt(plaintext, %User{id: id})

  defp encrypt(%{vault: :board_key}, id, plaintext),
    do: KeyVault.encrypt(plaintext, %Board{id: id})

  defp encrypt(%{vault: :site_key}, _id, plaintext), do: KeyVault.encrypt(plaintext, :site)
  defp encrypt(%{vault: :vapid}, _id, plaintext), do: VapidVault.encrypt(plaintext)

  defp id_of(%{encode: :base64}, value) do
    case Base.decode64(value) do
      {:ok, blob} -> id_of(nil, blob)
      :error -> "unreadable"
    end
  end

  defp id_of(_target, blob) do
    case Vault.key_id(blob) do
      {:ok, id} -> id
      :error -> "unreadable"
    end
  end

  defp unknown?(_purpose, "unreadable"), do: true
  defp unknown?(purpose, id), do: Keyring.fetch(purpose, id) == :error

  defp blank, do: %{rekeyed: 0, undecryptable: 0, skipped_concurrent: 0}

  defp add(acc, counts) do
    %{
      rekeyed: acc.rekeyed + counts.rekeyed,
      undecryptable: acc.undecryptable + counts.undecryptable,
      skipped_concurrent: acc.skipped_concurrent + counts.skipped_concurrent
    }
  end
end
