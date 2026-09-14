defmodule Baudrate.DataPortability.SysopExportTest do
  use Baudrate.DataCase, async: false

  import Ecto.Query

  alias Baudrate.{DataPortability, Repo}
  alias Baudrate.DataPortability.ExportRequest
  alias Baudrate.Notification.Notification, as: NotificationSchema
  alias Baudrate.Setup.User

  @base_url "https://bbs.example"

  setup do
    Baudrate.Setup.seed_roles_and_permissions()
    role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %User{}
      |> User.registration_changeset(%{
        "username" => "sysop_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    dir = Path.join(System.tmp_dir!(), "baudrate-sysop-out-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf(dir) end)

    %{user: user, dir: dir}
  end

  defp opts(extra \\ []),
    do: Keyword.merge([operator: "root", reason: "ticket 42", base_url: @base_url], extra)

  test "writes a private archive, records an audited request, and notifies the user",
       %{user: user, dir: dir} do
    # Banned users cannot self-export, which is exactly what this path is for.
    Repo.update_all(from(u in User, where: u.id == ^user.id), set: [status: "banned"])

    assert {:ok, path} = DataPortability.sysop_export(user.username, dir, opts())

    assert Path.dirname(path) == Baudrate.DataPortability.Files.realpath(dir) |> elem(1)
    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    {:ok, entries} = :zip.unzip(String.to_charlist(path), [:memory])
    names = Enum.map(entries, fn {n, _} -> List.to_string(n) end)
    assert "profile.json" in names

    assert [%ExportRequest{source: "sysop", status: "completed", operator: "root"}] =
             Repo.all(from(r in ExportRequest, where: r.user_id == ^user.id))

    assert [%{type: "data_export_downloaded", data: %{"source" => "sysop"}}] =
             Repo.all(from(n in NotificationSchema, where: n.user_id == ^user.id))
  end

  test "Release.export_user_data/3 wraps it for bin/baudrate eval", %{user: user, dir: dir} do
    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert {:ok, path} =
                 Baudrate.Release.export_user_data(user.username, dir,
                   operator: "root",
                   reason: "ticket 7"
                 )

        send(self(), {:path, path})
      end)

    assert_received {:path, path}
    assert output =~ "Export written to #{path}"

    refused =
      ExUnit.CaptureIO.capture_io(fn ->
        assert {:error, :reason_required} =
                 Baudrate.Release.export_user_data(user.username, dir, operator: "root")
      end)

    assert refused =~ "Export refused: :reason_required"
  end

  test "operator and reason are required", %{user: user, dir: dir} do
    assert {:error, :operator_required} =
             DataPortability.sysop_export(user.username, dir, opts(operator: " "))

    assert {:error, :reason_required} =
             DataPortability.sysop_export(user.username, dir, opts(reason: nil))
  end

  test "unknown users are refused", %{dir: dir} do
    assert {:error, :user_not_found} = DataPortability.sysop_export("no_such_user", dir, opts())
  end

  test "the output directory must be private and exist", %{user: user, dir: dir} do
    File.chmod!(dir, 0o750)

    assert {:error, :output_dir_not_private} =
             DataPortability.sysop_export(user.username, dir, opts())

    assert {:error, :output_dir_invalid} =
             DataPortability.sysop_export(user.username, Path.join(dir, "missing"), opts())

    assert Repo.aggregate(ExportRequest, :count) == 0
  end

  test "the output directory can never be inside a web root", %{user: user} do
    static = Application.app_dir(:baudrate, "priv/static")
    inside = Path.join(static, "sysop-export-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(inside)
    File.chmod!(inside, 0o700)
    on_exit(fn -> File.rm_rf(inside) end)

    assert {:error, :output_dir_forbidden} =
             DataPortability.sysop_export(user.username, inside, opts())

    assert File.ls!(inside) == []
  end
end
