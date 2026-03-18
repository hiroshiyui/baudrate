defmodule BaudrateWeb.ProfileLiveProfileFieldsTest do
  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.Auth
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    user = setup_user("user")
    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user}
  end

  describe "profile fields section" do
    test "renders profile fields form", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/profile")
      assert html =~ "Profile Fields"
      assert html =~ "Save Fields"
    end

    test "saves profile fields", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, "/profile")

      render_submit(lv, "save_profile_fields", %{
        "profile_fields" => %{
          "0" => %{"name" => "Website", "value" => "https://example.com"},
          "1" => %{"name" => "", "value" => ""},
          "2" => %{"name" => "", "value" => ""},
          "3" => %{"name" => "", "value" => ""}
        }
      })

      updated = Repo.get!(Baudrate.Setup.User, user.id)
      assert updated.profile_fields == [%{"name" => "Website", "value" => "https://example.com"}]
    end

    test "clears profile fields when all names are empty", %{conn: conn, user: user} do
      {:ok, _} =
        Auth.update_profile_fields(user, [%{"name" => "Old", "value" => "something"}])

      {:ok, lv, _html} = live(conn, "/profile")

      render_submit(lv, "save_profile_fields", %{
        "profile_fields" => %{
          "0" => %{"name" => "", "value" => ""},
          "1" => %{"name" => "", "value" => ""},
          "2" => %{"name" => "", "value" => ""},
          "3" => %{"name" => "", "value" => ""}
        }
      })

      updated = Repo.get!(Baudrate.Setup.User, user.id)
      assert updated.profile_fields == []
    end

    test "trims whitespace from field names and values", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, "/profile")

      render_submit(lv, "save_profile_fields", %{
        "profile_fields" => %{
          "0" => %{"name" => "  Website  ", "value" => "  https://example.com  "},
          "1" => %{"name" => "", "value" => ""},
          "2" => %{"name" => "", "value" => ""},
          "3" => %{"name" => "", "value" => ""}
        }
      })

      updated = Repo.get!(Baudrate.Setup.User, user.id)

      assert updated.profile_fields == [
               %{"name" => "Website", "value" => "https://example.com"}
             ]
    end

    test "handles missing profile_fields param gracefully", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, "/profile")
      render_submit(lv, "save_profile_fields", %{})

      updated = Repo.get!(Baudrate.Setup.User, user.id)
      assert updated.profile_fields == []
    end

    test "loads existing profile fields on mount", %{conn: conn, user: user} do
      {:ok, _} =
        Auth.update_profile_fields(user, [%{"name" => "Location", "value" => "Tokyo"}])

      {:ok, _lv, html} = live(conn, "/profile")
      assert html =~ "Location"
      assert html =~ "Tokyo"
    end

    test "shows success flash after saving", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/profile")

      html =
        render_submit(lv, "save_profile_fields", %{
          "profile_fields" => %{
            "0" => %{"name" => "Key", "value" => "Val"},
            "1" => %{"name" => "", "value" => ""},
            "2" => %{"name" => "", "value" => ""},
            "3" => %{"name" => "", "value" => ""}
          }
        })

      assert html =~ "Profile fields updated."
    end
  end
end
