defmodule BaudrateWeb.HelpersTest do
  use ExUnit.Case, async: true

  alias BaudrateWeb.Helpers

  describe "parse_id/1" do
    test "parses valid positive integer strings" do
      assert {:ok, 1} = Helpers.parse_id("1")
      assert {:ok, 42} = Helpers.parse_id("42")
      assert {:ok, 999_999} = Helpers.parse_id("999999")
    end

    test "rejects zero" do
      assert :error = Helpers.parse_id("0")
    end

    test "rejects negative numbers" do
      assert :error = Helpers.parse_id("-1")
      assert :error = Helpers.parse_id("-100")
    end

    test "rejects non-numeric strings" do
      assert :error = Helpers.parse_id("abc")
      assert :error = Helpers.parse_id("")
      assert :error = Helpers.parse_id("12abc")
      assert :error = Helpers.parse_id("1.5")
    end

    test "rejects non-binary input" do
      assert :error = Helpers.parse_id(nil)
      assert :error = Helpers.parse_id(42)
      assert :error = Helpers.parse_id(:atom)
    end
  end

  describe "password_strength/1" do
    test "returns all true when all criteria met" do
      result = Helpers.password_strength("Abcdefgh1234!")
      assert result.length == true
      assert result.lowercase == true
      assert result.uppercase == true
      assert result.digit == true
      assert result.special == true
    end

    test "missing lowercase" do
      result = Helpers.password_strength("ABCDEFGH1234!")
      assert result.lowercase == false
      assert result.uppercase == true
    end

    test "missing uppercase" do
      result = Helpers.password_strength("abcdefgh1234!")
      assert result.uppercase == false
      assert result.lowercase == true
    end

    test "missing digit" do
      result = Helpers.password_strength("Abcdefghijkl!")
      assert result.digit == false
      assert result.lowercase == true
    end

    test "missing special char" do
      result = Helpers.password_strength("Abcdefgh12345")
      assert result.special == false
      assert result.digit == true
    end

    test "too short" do
      result = Helpers.password_strength("Abc1!short")
      assert result.length == false
    end

    test "empty string returns all false" do
      result = Helpers.password_strength("")

      assert result == %{
               length: false,
               lowercase: false,
               uppercase: false,
               digit: false,
               special: false
             }
    end
  end

  describe "parse_page/1" do
    test "nil returns 1" do
      assert Helpers.parse_page(nil) == 1
    end

    test "valid page number" do
      assert Helpers.parse_page("3") == 3
    end

    test "zero returns 1" do
      assert Helpers.parse_page("0") == 1
    end

    test "negative returns 1" do
      assert Helpers.parse_page("-1") == 1
    end

    test "non-numeric returns 1" do
      assert Helpers.parse_page("abc") == 1
    end
  end

  describe "upload_error_to_string/2" do
    test ":too_large without max_size" do
      result = Helpers.upload_error_to_string(:too_large)
      assert is_binary(result)
      assert result =~ "too large" or result =~ "File"
    end

    test ":too_large with max_size" do
      result = Helpers.upload_error_to_string(:too_large, max_size: "5 MB")
      assert result =~ "5 MB"
    end

    test ":too_many_files without max_files" do
      result = Helpers.upload_error_to_string(:too_many_files)
      assert is_binary(result)
    end

    test ":too_many_files with max_files" do
      result = Helpers.upload_error_to_string(:too_many_files, max_files: 3)
      assert result =~ "3"
    end

    test ":not_accepted" do
      result = Helpers.upload_error_to_string(:not_accepted)
      assert is_binary(result)
    end

    test "unknown error" do
      result = Helpers.upload_error_to_string(:something_unknown)
      assert is_binary(result)
    end
  end

  describe "format_file_size/1" do
    test "bytes" do
      result = Helpers.format_file_size(500)
      assert result =~ "500"
      assert result =~ "B"
    end

    test "kilobytes" do
      result = Helpers.format_file_size(2048)
      assert result =~ "KB"
    end

    test "megabytes" do
      result = Helpers.format_file_size(5_242_880)
      assert result =~ "MB"
    end
  end

  describe "translate_role/1" do
    test "known roles return localized strings" do
      assert is_binary(Helpers.translate_role("admin"))
      assert is_binary(Helpers.translate_role("moderator"))
      assert is_binary(Helpers.translate_role("user"))
      assert is_binary(Helpers.translate_role("guest"))
    end

    test "unknown role passes through" do
      assert Helpers.translate_role("superadmin") == "superadmin"
    end
  end

  describe "translate_status/1" do
    test "known statuses return localized strings" do
      assert is_binary(Helpers.translate_status("active"))
      assert is_binary(Helpers.translate_status("pending"))
      assert is_binary(Helpers.translate_status("banned"))
    end

    test "unknown status passes through" do
      assert Helpers.translate_status("suspended") == "suspended"
    end
  end

  describe "translate_report_status/1" do
    test "known statuses return localized strings" do
      assert is_binary(Helpers.translate_report_status("open"))
      assert is_binary(Helpers.translate_report_status("resolved"))
      assert is_binary(Helpers.translate_report_status("dismissed"))
    end

    test "unknown status passes through" do
      assert Helpers.translate_report_status("escalated") == "escalated"
    end
  end

  describe "translate_delivery_status/1" do
    test "known statuses return localized strings" do
      assert is_binary(Helpers.translate_delivery_status("pending"))
      assert is_binary(Helpers.translate_delivery_status("delivered"))
      assert is_binary(Helpers.translate_delivery_status("failed"))
    end

    test "unknown status passes through" do
      assert Helpers.translate_delivery_status("retrying") == "retrying"
    end
  end

  describe "invite_url/1" do
    test "builds a full invite link URL" do
      url = Helpers.invite_url("abc12345")
      assert url =~ "/register?invite=abc12345"
      assert String.starts_with?(url, "http")
    end
  end

  describe "participant_name/1" do
    test "User struct returns username" do
      user = %Baudrate.Setup.User{username: "alice"}
      assert Helpers.participant_name(user) == "alice"
    end

    test "RemoteActor struct returns username@domain" do
      actor = %Baudrate.Federation.RemoteActor{username: "bob", domain: "remote.example"}
      assert Helpers.participant_name(actor) == "bob@remote.example"
    end

    test "unknown struct returns ?" do
      assert Helpers.participant_name(%{}) == "?"
    end
  end
end
