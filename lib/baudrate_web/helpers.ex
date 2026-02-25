defmodule BaudrateWeb.Helpers do
  @moduledoc """
  Shared helper functions for LiveView and controller parameter handling.
  """

  use BaudrateWeb, :verified_routes
  use Gettext, backend: BaudrateWeb.Gettext

  @doc """
  Formats a NaiveDateTime/DateTime in the site's configured timezone.

  Uses the `timezone` setting from `Baudrate.Setup`. Falls back to `"Etc/UTC"`
  when the setting is not configured.

  ## Examples

      iex> BaudrateWeb.Helpers.format_datetime(~N[2026-01-15 08:30:00])
      "2026-01-15 08:30"

      iex> BaudrateWeb.Helpers.format_datetime(~N[2026-01-15 08:30:00], "%Y-%m-%d")
      "2026-01-15"
  """
  def format_datetime(datetime, format \\ "%Y-%m-%d %H:%M")

  def format_datetime(nil, _format), do: ""

  def format_datetime(%NaiveDateTime{} = ndt, format) do
    tz = Baudrate.Setup.get_setting("timezone") || "Etc/UTC"

    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.shift_zone!(tz)
    |> Calendar.strftime(format)
  end

  def format_datetime(%DateTime{} = dt, format) do
    tz = Baudrate.Setup.get_setting("timezone") || "Etc/UTC"

    dt
    |> DateTime.shift_zone!(tz)
    |> Calendar.strftime(format)
  end

  @doc """
  Returns an ISO datetime string for the HTML `datetime` attribute.

  ## Examples

      iex> BaudrateWeb.Helpers.datetime_attr(~N[2026-01-15 08:30:00])
      "2026-01-15T08:30:00"
  """
  def datetime_attr(datetime) do
    format_datetime(datetime, "%Y-%m-%dT%H:%M:%S")
  end

  @doc """
  Formats a date only (no time portion).

  ## Examples

      iex> BaudrateWeb.Helpers.format_date(~N[2026-01-15 08:30:00])
      "2026-01-15"
  """
  def format_date(datetime) do
    format_datetime(datetime, "%Y-%m-%d")
  end

  @doc """
  Safely parses a string parameter to a positive integer.
  Returns `{:ok, integer}` on success, `:error` on failure.

  ## Examples

      iex> BaudrateWeb.Helpers.parse_id("42")
      {:ok, 42}

      iex> BaudrateWeb.Helpers.parse_id("abc")
      :error

      iex> BaudrateWeb.Helpers.parse_id("-1")
      :error

      iex> BaudrateWeb.Helpers.parse_id("0")
      :error
  """
  def parse_id(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> :error
    end
  end

  def parse_id(_), do: :error

  @doc """
  Parses a page number from a string parameter.
  Returns 1 for nil, invalid, or non-positive values.

  ## Examples

      iex> BaudrateWeb.Helpers.parse_page("3")
      3

      iex> BaudrateWeb.Helpers.parse_page(nil)
      1

      iex> BaudrateWeb.Helpers.parse_page("abc")
      1
  """
  def parse_page(nil), do: 1

  def parse_page(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end

  @doc """
  Evaluates password strength criteria for UI feedback.

  Returns a map of boolean flags for each criterion:
  `:length`, `:lowercase`, `:uppercase`, `:digit`, `:special`.
  """
  def password_strength(password) do
    %{
      length: String.length(password) >= 12,
      lowercase: Regex.match?(~r/[a-z]/, password),
      uppercase: Regex.match?(~r/[A-Z]/, password),
      digit: Regex.match?(~r/[0-9]/, password),
      special: Regex.match?(~r/[^a-zA-Z0-9]/, password)
    }
  end

  @doc """
  Translates a file upload error to a human-readable string.

  Accepts optional keyword options:
  - `:max_size` — display string for the max file size (e.g. `"5 MB"`)
  - `:max_files` — display value for the max number of files

  ## Examples

      iex> BaudrateWeb.Helpers.upload_error_to_string(:too_large, max_size: "5 MB")
      "File too large (max 5 MB)"

      iex> BaudrateWeb.Helpers.upload_error_to_string(:not_accepted)
      "File type not accepted"
  """
  def upload_error_to_string(error, opts \\ [])

  def upload_error_to_string(:too_large, opts) do
    case Keyword.get(opts, :max_size) do
      nil -> gettext("File too large")
      size -> gettext("File too large (max %{size})", size: size)
    end
  end

  def upload_error_to_string(:too_many_files, opts) do
    case Keyword.get(opts, :max_files) do
      nil -> gettext("Too many files")
      n -> gettext("Too many files (max %{n})", n: n)
    end
  end

  def upload_error_to_string(:not_accepted, _opts), do: gettext("File type not accepted")
  def upload_error_to_string(_, _opts), do: gettext("Upload error")

  @doc """
  Translates a role name to a localized display string.
  """
  def translate_role("admin"), do: gettext("admin")
  def translate_role("moderator"), do: gettext("moderator")
  def translate_role("user"), do: gettext("user")
  def translate_role("guest"), do: gettext("guest")
  def translate_role(other), do: other

  @doc """
  Returns a human-friendly display name for a user or remote actor.

  Falls back to `username` when `display_name` is nil or empty.
  """
  def display_name(%Baudrate.Setup.User{display_name: dn})
      when is_binary(dn) and dn != "",
      do: dn

  def display_name(%Baudrate.Setup.User{username: username}), do: username

  def display_name(%Baudrate.Federation.RemoteActor{display_name: dn})
      when is_binary(dn) and dn != "",
      do: dn

  def display_name(%Baudrate.Federation.RemoteActor{username: username}), do: username

  @doc """
  Returns a display name for a conversation participant.

  Local users show their display name; remote actors show `display_name` or `username@domain`.
  """
  def participant_name(%Baudrate.Setup.User{} = user), do: display_name(user)

  def participant_name(%Baudrate.Federation.RemoteActor{} = actor),
    do: "#{display_name(actor)}@#{actor.domain}"

  def participant_name(_), do: "?"

  @doc """
  Translates a user status to a localized display string.
  """
  def translate_status("active"), do: gettext("active")
  def translate_status("pending"), do: gettext("pending")
  def translate_status("banned"), do: gettext("banned")
  def translate_status(other), do: other

  @doc """
  Translates a report status to a localized display string.
  """
  def translate_report_status("open"), do: gettext("open")
  def translate_report_status("resolved"), do: gettext("resolved")
  def translate_report_status("dismissed"), do: gettext("dismissed")
  def translate_report_status(other), do: other

  @doc """
  Builds a full invite link URL for the given invite code string.

  ## Examples

      iex> BaudrateWeb.Helpers.invite_url("abc12345")
      BaudrateWeb.Endpoint.url() <> "/register?invite=abc12345"
  """
  def invite_url(code) when is_binary(code) do
    BaudrateWeb.Endpoint.url() <> "/register?invite=" <> code
  end

  @doc """
  Translates a delivery job status to a localized display string.
  """
  def translate_delivery_status("pending"), do: gettext("pending")
  def translate_delivery_status("delivered"), do: gettext("delivered")
  def translate_delivery_status("failed"), do: gettext("failed")
  def translate_delivery_status(other), do: other

  @doc """
  Formats a file size in bytes to a human-readable string with localized units.

  ## Examples

      iex> BaudrateWeb.Helpers.format_file_size(500)
      "500 B"

      iex> BaudrateWeb.Helpers.format_file_size(2048)
      "2.0 KB"
  """
  def format_file_size(bytes) when bytes < 1024,
    do: gettext("%{n} B", n: bytes)

  def format_file_size(bytes) when bytes < 1_048_576,
    do: gettext("%{n} KB", n: Float.round(bytes / 1024, 1))

  def format_file_size(bytes),
    do: gettext("%{n} MB", n: Float.round(bytes / 1_048_576, 1))
end
