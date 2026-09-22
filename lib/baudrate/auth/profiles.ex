defmodule Baudrate.Auth.Profiles do
  @moduledoc """
  Handles updates to user profiles, locale preferences, and notification settings.

  ## What a sanction stops here

  The parts of a profile other people read — display name, bio, avatar,
  signature and profile fields — go through `Auth.ensure_can_interact/1`
  (ADR 0029). A bio is a billboard, and silencing someone who is then free to
  rewrite theirs at the person they were harassing achieves nothing.

  The parts only the account itself sees or that make it *safer* — preferred
  locales, notification preferences and `dm_access` — are deliberately left
  open. Narrowing who may DM you is not something a sanction should prevent.
  """

  alias Baudrate.Auth.Sanctions
  alias Baudrate.Auth.Trust
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
    with_interaction(user, fn ->
      user
      |> User.avatar_changeset(%{avatar_id: avatar_id})
      |> Repo.update()
    end)
  end

  @doc """
  Removes a user's avatar by setting avatar_id to nil.
  """
  @spec remove_avatar(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def remove_avatar(user) do
    with_interaction(user, fn ->
      user
      |> User.avatar_changeset(%{avatar_id: nil})
      |> Repo.update()
    end)
  end

  @doc """
  Updates a user's signature.

  A signature is Markdown shown under every article the account posts, so an
  account still under the limits on new accounts may not add a link or an
  image to it (`Baudrate.Auth.Trust.check_signature/3`, ADR 0064). The
  comparison is with the signature as stored, not as the caller last saw it.
  """
  def update_signature(user, signature) do
    stored = Repo.get(User, user.id)

    with :ok <- Sanctions.ensure_can_interact(user),
         :ok <- Trust.check_signature(user, signature, stored && stored.signature) do
      with_interaction(user, fn ->
        user
        |> User.signature_changeset(%{signature: signature})
        |> Repo.update()
      end)
    end
  end

  @doc """
  Updates a user's display name. Pass `nil` or empty string to clear.
  """
  def update_display_name(user, display_name) do
    with_interaction(user, fn ->
      user
      |> User.display_name_changeset(%{display_name: display_name})
      |> Repo.update()
    end)
  end

  @doc """
  Updates a user's bio.
  """
  def update_bio(user, bio) do
    with_interaction(user, fn ->
      user
      |> User.bio_changeset(%{bio: bio})
      |> Repo.update()
    end)
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
    with_interaction(user, fn ->
      user
      |> User.profile_fields_changeset(%{profile_fields: fields})
      |> Repo.update()
    end)
  end

  # A restricted account cannot change what other people read on its profile.
  #
  # The same wrapper tells the account's remote followers, because the parts a
  # sanction protects and the parts an `Update(Person)` carries are the same
  # parts — what other people read (ADR 0051's sibling case: the profile is
  # published, so a change to it has to be). `Federation.update_actor/3`
  # compares the rendered document and sends nothing when it is unchanged, so
  # the three functions below that do *not* appear in a `Person` — locales,
  # notification preferences, `dm_access` — keep going through the plain path
  # and cost nothing.
  defp with_interaction(user, fun) do
    case Sanctions.ensure_can_interact(user) do
      :ok -> Baudrate.Federation.update_actor(:user, user, fun)
      {:error, _reason} = error -> error
    end
  end
end
