defmodule Baudrate.Auth.Profiles do
  @moduledoc """
  Handles updates to user profiles, locale preferences, and notification settings.
  """

  alias Baudrate.Repo
  alias Baudrate.Setup.User

  @doc """
  Updates a user's preferred locales list.

  Validates that all entries are known Gettext locales via `User.locale_changeset/2`.
  Returns `{:ok, user}` or `{:error, changeset}`.
  """
  def update_preferred_locales(user, locales) when is_list(locales) do
    user
    |> User.locale_changeset(%{preferred_locales: locales})
    |> Repo.update()
  end

  @doc """
  Updates a user's avatar_id.
  """
  @spec update_avatar(User.t(), integer() | nil) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_avatar(user, avatar_id) do
    user
    |> User.avatar_changeset(%{avatar_id: avatar_id})
    |> Repo.update()
  end

  @doc """
  Removes a user's avatar by setting avatar_id to nil.
  """
  @spec remove_avatar(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def remove_avatar(user) do
    user
    |> User.avatar_changeset(%{avatar_id: nil})
    |> Repo.update()
  end

  @doc """
  Updates a user's signature.
  """
  def update_signature(user, signature) do
    user
    |> User.signature_changeset(%{signature: signature})
    |> Repo.update()
  end

  @doc """
  Updates a user's display name. Pass `nil` or empty string to clear.
  """
  def update_display_name(user, display_name) do
    user
    |> User.display_name_changeset(%{display_name: display_name})
    |> Repo.update()
  end

  @doc """
  Updates a user's bio.
  """
  def update_bio(user, bio) do
    user
    |> User.bio_changeset(%{bio: bio})
    |> Repo.update()
  end

  @doc """
  Updates a user's DM access preference.

  Valid values: `"anyone"`, `"followers"`, `"nobody"`.
  """
  def update_dm_access(user, value) when is_binary(value) do
    user
    |> User.dm_access_changeset(%{dm_access: value})
    |> Repo.update()
  end

  @doc """
  Updates a user's notification preferences map.

  The `prefs` map has notification type keys (e.g. `"mention"`) with value
  maps like `%{"in_app" => false}`. Returns `{:ok, user}` or `{:error, changeset}`.
  """
  def update_notification_preferences(user, prefs) when is_map(prefs) do
    user
    |> User.notification_preferences_changeset(%{notification_preferences: prefs})
    |> Repo.update()
  end

  @doc """
  Updates a user's profile fields (custom metadata key-value pairs).

  Accepts a list of up to 4 maps, each with `"name"` and `"value"` string keys.
  Empty-name entries should be filtered out by the caller before passing.
  Returns `{:ok, user}` or `{:error, changeset}`.
  """
  def update_profile_fields(user, fields) when is_list(fields) do
    user
    |> User.profile_fields_changeset(%{profile_fields: fields})
    |> Repo.update()
  end
end
