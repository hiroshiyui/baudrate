defmodule BaudrateWeb.Features.DataExportTest do
  use BaudrateWeb.FeatureCase, async: false

  import Ecto.Query

  alias Baudrate.{DataPortability, Repo}
  alias Baudrate.Setup.User
  alias Baudrate.DataPortability.ExportRequest

  @moduletag :feature

  @downloads Path.expand("../../../tmp/wallaby_downloads", __DIR__)

  # The download is a form POST that the controller accepts only with the Fetch
  # Metadata headers a real browser navigation sends (ADR 0023), so this is the
  # only test that shows a member can actually get their archive.
  feature "a member requests an export and downloads the archive once it is ready", %{
    session: session
  } do
    {user, secret} = enable_totp!(setup_user("user"))
    eight_days_ago = DateTime.utc_now() |> DateTime.add(-8 * 86_400) |> DateTime.truncate(:second)

    Repo.update_all(from(u in User, where: u.id == ^user.id),
      set: [totp_enabled_at: eight_days_ago]
    )

    File.mkdir_p!(@downloads)
    archive_glob = Path.join(@downloads, "baudrate-export-#{user.username}-*.zip")
    Enum.each(Path.wildcard(archive_glob), &File.rm!/1)

    session
    |> log_in_with_totp_via_browser(user, secret)
    |> visit("/profile/export")
    |> fill_in(Query.css("#export_request_password"), with: "Password123!x")
    |> fill_in(Query.css("#export_request_code"), with: totp_code(user, secret))
    |> click(Query.css("#data-export-request-submit"))
    |> assert_has(Query.css("#data-export-active"))

    request = Repo.get_by!(ExportRequest, user_id: user.id)
    make_ready(request)

    session
    |> visit("/profile/export")
    |> fill_in(Query.css("#export_download_password"), with: "Password123!x")
    |> fill_in(Query.css("#export_download_code"), with: totp_code(user, secret))
    |> click(Query.css("#data-export-download-submit"))

    {archive, entries} = wait_for_archive(archive_glob, 150)
    assert length(entries) > 1
    assert Repo.reload!(request).download_count == 1

    File.rm!(archive)
  end

  # Moves the request 24 hours (plus a minute) into the past, as if it had
  # been made yesterday.
  defp make_ready(request) do
    shift = DataPortability.ready_delay_seconds() + 60

    Repo.update_all(from(r in ExportRequest, where: r.id == ^request.id),
      set: [
        requested_at: DateTime.add(request.requested_at, -shift),
        ready_at: DateTime.add(request.ready_at, -shift),
        expires_at: DateTime.add(request.expires_at, -shift)
      ]
    )
  end

  defp wait_for_archive(glob, 0), do: flunk("no complete download matching #{glob}")

  # Firefox creates the final file as an empty placeholder and writes the
  # download to a .part file beside it, so wait until that is gone and the
  # archive reads as a zip.
  defp wait_for_archive(glob, tries) do
    with [path] <- Path.wildcard(glob),
         false <- File.exists?(path <> ".part"),
         {:ok, entries} <- :zip.table(String.to_charlist(path)) do
      {path, entries}
    else
      _ -> Process.sleep(100) && wait_for_archive(glob, tries - 1)
    end
  end
end
