defmodule Baudrate.Setup do
  @moduledoc """
  The Setup context handles first-time application configuration.

  On first visit, the `EnsureSetup` plug redirects all routes to `/setup`,
  which renders a multi-step wizard (see `SetupLive`). This context provides
  the backing logic: database checks, role/permission seeding, and the atomic
  `complete_setup/2` transaction.

  ## RBAC Design

  Roles and permissions use a normalized 3-table design:

    * `roles` — named roles (admin, moderator, user, guest)
    * `permissions` — named capabilities (e.g., `"admin.manage_users"`)
    * `role_permissions` — join table mapping roles to their permissions

  ## Permission Hierarchy

  Permissions follow a `scope.action` naming convention. Roles are a fixed,
  totally ordered set (ADR 0042):

      admin > moderator > user > guest

  **There is no runtime inheritance.** `has_permission?/2` does an exact
  `(role_name, permission_name)` join, so a higher role holds a lower role's
  permission only because `default_permissions/0` lists it again — the counts
  are flattened copies, written once by `seed_roles_and_permissions/0`. Adding
  a permission to `user` here does not give it to `admin`.

  The matrix has no write path: nothing outside seeding edits
  `role_permissions`, so `has_permission?/2` is a constant function of the map
  below. Four of the eleven permissions are consulted at runtime
  (`admin.manage_roles`, `moderator.sanction_user`, `admin.manage_users`,
  `user.create_content`); the rest are documentation, and
  `test/baudrate/setup/permissions_are_enforced_test.exs` names them so the
  gap cannot widen unnoticed. ADR 0042 records why this is the accepted state
  rather than a bug to fix.

  The full matrix is defined in `default_permissions/0`.

  ## Admin Settings

  `change_settings/1` and `save_settings/1` provide virtual-changeset-based
  management of site-wide settings (site name, registration mode and its
  challenge difficulty, the limits on new accounts, how many first posts are
  held, timezone, federation mode and allowlist, themes) used by the admin
  settings UI. Blocked domains are rows of their own (ADR 0030), not a
  setting.

  `federation_enabled?/0` returns whether federation is active (defaults to true).

  ## Atomic Setup

  `complete_setup/2` runs the entire setup in a single `Ecto.Multi` transaction:
  site name → roles/permissions → admin user → `setup_completed` flag. If any
  step fails, the entire setup is rolled back.
  """

  import Ecto.Query
  alias Baudrate.Repo
  alias Baudrate.Content
  alias Baudrate.Setup.{Permission, Role, RolePermission, Rule, Setting, User}

  @doc """
  Returns the permission matrix as a map of role name to list of permission names.
  Pure function, no database access.
  """
  def default_permissions do
    %{
      "admin" => [
        "admin.manage_users",
        "admin.manage_settings",
        "admin.manage_roles",
        "moderator.manage_content",
        "moderator.manage_comments",
        "moderator.view_reports",
        "moderator.sanction_user",
        "user.create_content",
        "user.edit_own_content",
        "user.manage_profile",
        "guest.view_content"
      ],
      "moderator" => [
        "moderator.manage_content",
        "moderator.manage_comments",
        "moderator.view_reports",
        "moderator.sanction_user",
        "user.create_content",
        "user.edit_own_content",
        "user.manage_profile",
        "guest.view_content"
      ],
      "user" => [
        "user.create_content",
        "user.edit_own_content",
        "user.manage_profile",
        "guest.view_content"
      ],
      "guest" => [
        "guest.view_content"
      ]
    }
  end

  @role_descriptions %{
    "admin" => "Full system access",
    "moderator" => "Content and user moderation",
    "user" => "Standard user access",
    "guest" => "Read-only access"
  }

  @permission_descriptions %{
    "admin.manage_users" => "Create, edit, and delete users",
    "admin.manage_settings" => "Modify system settings",
    "admin.manage_roles" => "Manage roles and permissions",
    "moderator.manage_content" => "Edit and remove content",
    "moderator.manage_comments" => "Manage comments",
    "moderator.view_reports" => "View moderation reports",
    "moderator.sanction_user" => "Warn, silence and suspend accounts",
    "user.create_content" => "Create new content",
    "user.edit_own_content" => "Edit own content",
    "user.manage_profile" => "Manage own profile",
    "guest.view_content" => "View published content"
  }

  @default_light_theme "aquaosx"
  @default_dark_theme "aquaosxdark"

  @daisyui_themes [
    # Light themes
    {"light", "Light", :light},
    {"cupcake", "Cupcake", :light},
    {"bumblebee", "Bumblebee", :light},
    {"emerald", "Emerald", :light},
    {"corporate", "Corporate", :light},
    {"retro", "Retro", :light},
    {"cyberpunk", "Cyberpunk", :light},
    {"valentine", "Valentine", :light},
    {"garden", "Garden", :light},
    {"lofi", "Lo-Fi", :light},
    {"pastel", "Pastel", :light},
    {"fantasy", "Fantasy", :light},
    {"wireframe", "Wireframe", :light},
    {"cmyk", "CMYK", :light},
    {"autumn", "Autumn", :light},
    {"lemonade", "Lemonade", :light},
    {"winter", "Winter", :light},
    {"acid", "Acid", :light},
    {"caramellatte", "Caramellatte", :light},
    {"silk", "Silk", :light},
    {"nord", "Nord", :light},
    {"aquaosx", "Mac OS X (Aqua) (Default)", :light},
    # Dark themes
    {"dark", "Dark", :dark},
    {"synthwave", "Synthwave", :dark},
    {"halloween", "Halloween", :dark},
    {"forest", "Forest", :dark},
    {"aqua", "Aqua", :dark},
    {"black", "Black", :dark},
    {"luxury", "Luxury", :dark},
    {"dracula", "Dracula", :dark},
    {"night", "Night", :dark},
    {"coffee", "Coffee", :dark},
    {"business", "Business", :dark},
    {"dim", "Dim", :dark},
    {"sunset", "Sunset", :dark},
    {"abyss", "Abyss", :dark},
    {"aquaosxdark", "Mac OS X (Aqua) Dark (Default)", :dark}
  ]

  @daisyui_theme_names Enum.map(@daisyui_themes, fn {name, _, _} -> name end)

  @doc """
  Returns the list of all DaisyUI themes as `{name, label, scheme}` tuples.
  """
  def daisyui_themes, do: @daisyui_themes

  @doc """
  The theme used for light mode when no `theme_light` setting is stored.
  """
  def default_light_theme, do: @default_light_theme

  @doc """
  The theme used for dark mode when no `theme_dark` setting is stored.
  """
  def default_dark_theme, do: @default_dark_theme

  @doc """
  Returns light-scheme themes as `{label, name}` tuples for select options.
  """
  def light_theme_options do
    for {name, label, :light} <- @daisyui_themes, do: {label, name}
  end

  @doc """
  Returns dark-scheme themes as `{label, name}` tuples for select options.
  """
  def dark_theme_options do
    for {name, label, :dark} <- @daisyui_themes, do: {label, name}
  end

  @doc """
  Returns the admin-configured theme settings.

  Returns `%{light: theme_name, dark: theme_name}`.
  """
  def get_theme_settings do
    %{
      light: get_setting("theme_light") || @default_light_theme,
      dark: get_setting("theme_dark") || @default_dark_theme
    }
  end

  @role_levels %{"guest" => 0, "user" => 1, "moderator" => 2, "admin" => 3}

  @doc """
  Returns the numeric level for a role name (guest=0, user=1, moderator=2, admin=3).
  Unknown roles default to 0.
  """
  @spec role_level(String.t()) :: non_neg_integer()
  def role_level(role_name), do: Map.get(@role_levels, role_name, 0)

  @doc """
  Returns a list of role names whose level is at or below the given role's level.

  ## Examples

      iex> roles_at_or_below("user")
      ["guest", "user"]

      iex> roles_at_or_below("admin")
      ["guest", "user", "moderator", "admin"]
  """
  @spec roles_at_or_below(String.t()) :: [String.t()]
  def roles_at_or_below(role_name) do
    max_level = role_level(role_name)

    @role_levels
    |> Enum.filter(fn {_name, lvl} -> lvl <= max_level end)
    |> Enum.sort_by(fn {_name, lvl} -> lvl end)
    |> Enum.map(fn {name, _lvl} -> name end)
  end

  @doc """
  Returns true if the user's role meets or exceeds the minimum required role.
  """
  @spec role_meets_minimum?(String.t(), String.t()) :: boolean()
  def role_meets_minimum?(user_role_name, min_role_name) do
    role_level(user_role_name) >= role_level(min_role_name)
  end

  @doc """
  Returns the value of a setting by key, or nil if not found.

  In production, reads from the ETS-backed `SettingsCache` for O(1) lookups.
  In test environment, reads directly from the database to avoid cross-test
  interference via the shared ETS table.
  """
  @spec get_setting(String.t()) :: String.t() | nil
  def get_setting(key) when is_binary(key) do
    if Application.get_env(:baudrate, :settings_cache_enabled, true) do
      Baudrate.Setup.SettingsCache.get(key)
    else
      Repo.one(from s in Setting, where: s.key == ^key, select: s.value)
    end
  end

  @domain_block_keys ~w(ap_federation_mode ap_domain_allowlist)

  @doc """
  Upserts a setting by key. Creates or updates the setting.

  Writing the federation mode or the allowlist also refreshes
  `Baudrate.Federation.DomainBlockCache`. Blocked domains are rows rather than
  a setting (ADR 0030); `Federation.DomainBlocks` refreshes the cache for them.
  """
  @spec set_setting(String.t(), String.t()) :: {:ok, Setting.t()} | {:error, Ecto.Changeset.t()}
  def set_setting(key, value) when is_binary(key) and is_binary(value) do
    result =
      case Repo.one(from s in Setting, where: s.key == ^key) do
        nil ->
          %Setting{}
          |> Setting.changeset(%{key: key, value: value})
          |> Repo.insert()

        setting ->
          setting
          |> Setting.changeset(%{value: value})
          |> Repo.update()
      end

    if Application.get_env(:baudrate, :settings_cache_enabled, true) do
      case result do
        {:ok, _} -> Baudrate.Setup.SettingsCache.put(key, value)
        _ -> :ok
      end
    end

    # Federation checks read domain blocks from their own ETS cache, so a
    # write to any of these keys must reach it too, whichever caller made it.
    if key in @domain_block_keys and match?({:ok, _}, result) do
      Baudrate.Federation.DomainBlockCache.refresh()
    end

    result
  end

  @doc """
  Returns the current registration mode. Defaults to `"approval_required"`.

  Possible values:
    * `"open"` — users are immediately active after registration
    * `"approval_required"` — users are created with `"pending"` status
  """
  def registration_mode do
    get_setting("registration_mode") || "approval_required"
  end

  @doc """
  Returns true if federation is enabled. Defaults to true when unset.
  """
  def federation_enabled? do
    get_setting("ap_federation_enabled") != "false"
  end

  @doc """
  Returns the End User Agreement text (markdown), or `nil` if not set.
  """
  def get_eua do
    get_setting("eua")
  end

  @doc """
  Saves or updates the End User Agreement text (markdown).
  """
  def update_eua(text) when is_binary(text) do
    set_setting("eua", text)
  end

  @doc """
  The version of the terms members are currently required to have accepted.

  It moves only when an admin deliberately publishes (`publish_terms_version/0`),
  never on an ordinary save: a typo fix must not confront a whole instance with
  a banner, or admins learn to avoid correcting typos.

  An unreadable value reads as 0 — nobody is asked to accept again. This is a
  courtesy prompt, not an access control, and a malformed settings row is a
  poor reason to pause every member on the site.
  """
  @spec current_terms_version() :: non_neg_integer()
  def current_terms_version do
    with value when is_binary(value) <- get_setting("eua_version"),
         {n, _rest} when n >= 0 <- Integer.parse(value) do
      n
    else
      _ -> 0
    end
  end

  @doc """
  Publishes the terms as a new version, so every member must accept them again
  before posting or interacting. Reading is never affected.

  Two admins publishing at once can both read the same version and write the
  same next one; the result is what either intended, so the read is not locked.
  """
  @spec publish_terms_version() :: {:ok, pos_integer()} | {:error, Ecto.Changeset.t()}
  def publish_terms_version do
    next = current_terms_version() + 1

    case set_setting("eua_version", Integer.to_string(next)) do
      {:ok, _setting} -> {:ok, next}
      {:error, changeset} -> {:error, changeset}
    end
  end

  # The single-document policies, as `live_action` => settings key. The terms
  # keep the historical `"eua"` key: renaming it would orphan the text every
  # existing instance has already written. The site rules are **not** here —
  # they are records, so a report can cite one (P1-D9, `Setup.Rule`).
  @policy_keys %{terms: "eua", privacy: "privacy_policy"}

  @doc """
  Returns the names of the public policy documents, in the order the footer
  lists them.
  """
  @spec policy_names() :: [atom()]
  def policy_names, do: [:terms, :rules, :privacy]

  @doc """
  Returns one single-document policy as markdown, or `nil` when the admin has
  not written it yet. The site rules are records; use `list_rules/0`.
  """
  @spec get_policy(atom()) :: String.t() | nil
  def get_policy(name) when is_map_key(@policy_keys, name) do
    get_setting(Map.fetch!(@policy_keys, name))
  end

  @doc """
  Returns the policy documents an admin has actually written.

  The footer links these and only these: a link to a page that says the
  document has not been published yet is worse than no link, and on a fresh
  instance all three are unwritten.
  """
  @spec published_policies() :: [atom()]
  def published_policies do
    Enum.filter(policy_names(), &policy_published?/1)
  end

  defp policy_published?(:rules), do: Repo.exists?(active_rules_query())

  defp policy_published?(name) do
    case get_policy(name) do
      nil -> false
      text -> String.trim(text) != ""
    end
  end

  @doc """
  Saves one single-document policy. The terms have their own writer
  (`update_eua/1`) because publishing them can also require every member to
  accept again.
  """
  @spec update_policy(atom(), String.t()) :: {:ok, Setting.t()} | {:error, Ecto.Changeset.t()}
  def update_policy(name, text) when name == :privacy and is_binary(text) do
    set_setting(Map.fetch!(@policy_keys, name), text)
  end

  ## Site rules (P1-D9)

  defp active_rules_query do
    from(r in Rule, where: is_nil(r.retired_at), order_by: [asc: r.position, asc: r.id])
  end

  @doc """
  The published rules, in the order they are numbered on `/rules`.
  """
  @spec list_rules() :: [Rule.t()]
  def list_rules, do: Repo.all(active_rules_query())

  @doc """
  Rules that have been retired, most recently retired first. Shown to admins so
  a rule taken down by mistake can be put back.
  """
  @spec list_retired_rules() :: [Rule.t()]
  def list_retired_rules do
    Repo.all(from(r in Rule, where: not is_nil(r.retired_at), order_by: [desc: r.retired_at]))
  end

  @doc """
  One rule by id, retired or not — a report may cite a rule that has since been
  retired, and the moderator still needs to see which one.
  """
  @spec get_rule(integer()) :: Rule.t() | nil
  def get_rule(id) when is_integer(id), do: Repo.get(Rule, id)
  def get_rule(_), do: nil

  @doc """
  Adds a rule at the end of the list.

  The position is assigned here and never comes from the form: an admin typing
  a number is how two rules end up claiming the same place.
  """
  @spec create_rule(map()) :: {:ok, Rule.t()} | {:error, Ecto.Changeset.t()}
  def create_rule(attrs) do
    %Rule{}
    |> Rule.changeset(attrs)
    |> Ecto.Changeset.put_change(:position, next_rule_position())
    |> Repo.insert()
  end

  # Counted over every row, retired ones included, so retiring a rule never
  # hands its number to a different one.
  defp next_rule_position do
    (Repo.one(from(r in Rule, select: max(r.position))) || 0) + 1
  end

  @doc "Rewrites a rule's title and body."
  @spec update_rule(Rule.t(), map()) :: {:ok, Rule.t()} | {:error, Ecto.Changeset.t()}
  def update_rule(%Rule{} = rule, attrs) do
    rule |> Rule.changeset(attrs) |> Repo.update()
  end

  @doc """
  Retires a rule: it leaves `/rules` and the report dialog, and past reports
  citing it still resolve. Returns `{:error, :already_retired}` so the original
  decision keeps its date.
  """
  @spec retire_rule(Rule.t()) :: {:ok, Rule.t()} | {:error, :already_retired | Ecto.Changeset.t()}
  def retire_rule(%Rule{retired_at: %DateTime{}}), do: {:error, :already_retired}

  def retire_rule(%Rule{} = rule) do
    rule
    |> Ecto.Changeset.change(retired_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update()
  end

  @doc "Puts a retired rule back on the list, at the end."
  @spec restore_rule(Rule.t()) :: {:ok, Rule.t()} | {:error, :not_retired | Ecto.Changeset.t()}
  def restore_rule(%Rule{retired_at: nil}), do: {:error, :not_retired}

  def restore_rule(%Rule{} = rule) do
    rule
    |> Ecto.Changeset.change(retired_at: nil, position: next_rule_position())
    |> Repo.update()
  end

  @doc """
  Moves a rule one place up or down the list.

  The two rules swap positions inside a transaction: writing one and then the
  other would leave the list briefly (or, on a failure, permanently) with two
  rules claiming the same place.
  """
  @spec move_rule(Rule.t(), :up | :down) :: {:ok, Rule.t()} | {:error, :at_edge}
  def move_rule(%Rule{} = rule, direction) when direction in [:up, :down] do
    case neighbour(rule, direction) do
      nil ->
        {:error, :at_edge}

      %Rule{} = other ->
        Repo.transaction(fn ->
          {:ok, _} = rule |> Ecto.Changeset.change(position: other.position) |> Repo.update()
          {:ok, _} = other |> Ecto.Changeset.change(position: rule.position) |> Repo.update()
          Repo.reload(rule)
        end)
    end
  end

  defp neighbour(%Rule{position: position}, :up) do
    active_rules_query()
    |> exclude(:order_by)
    |> where([r], r.position < ^position)
    |> order_by([r], desc: r.position)
    |> limit(1)
    |> Repo.one()
  end

  defp neighbour(%Rule{position: position}, :down) do
    active_rules_query()
    |> exclude(:order_by)
    |> where([r], r.position > ^position)
    |> order_by([r], asc: r.position)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Returns true when at least one rule is published, so a `rule_violation`
  report has something to cite.
  """
  @spec rules_published?() :: boolean()
  def rules_published?, do: Repo.exists?(active_rules_query())

  @doc """
  Returns true if the setup wizard has been completed.
  """
  def setup_completed? do
    Repo.exists?(from s in Setting, where: s.key == "setup_completed" and s.value == "true")
  end

  @doc """
  Checks the database connection and returns version info.
  """
  def check_database do
    case Repo.query("SELECT version(), current_database()") do
      {:ok, %{rows: [[version, database]]}} ->
        {:ok, %{version: version, database: database}}

      {:error, error} ->
        {:error, Exception.message(error)}
    end
  end

  @doc """
  Checks if all migrations have been run.
  """
  def check_migrations do
    migrations = Ecto.Migrator.migrations(Repo)

    pending =
      Enum.filter(migrations, fn {status, _version, _name} -> status == :down end)

    if pending == [] do
      {:ok, length(migrations)}
    else
      {:error, pending}
    end
  end

  @valid_registration_modes ~w(open approval_required invite_only)
  @valid_federation_modes ~w(blocklist allowlist)

  @doc """
  Returns a virtual changeset for admin settings: site name and description,
  registration mode and challenge difficulty, the limits on new accounts
  (ADR 0064), how many first posts are held (ADR 0065), timezone, federation
  options and themes.

  Used by `Admin.SettingsLive` for form validation.
  """
  def change_settings(attrs \\ %{}) do
    types = %{
      site_name: :string,
      site_description: :string,
      site_contact: :string,
      registration_mode: :string,
      registration_challenge_bits: :integer,
      new_account_days: :integer,
      new_account_posts: :integer,
      hold_first_posts: :integer,
      timezone: :string,
      ap_federation_enabled: :string,
      ap_federation_mode: :string,
      ap_domain_allowlist: :string,
      ap_authorized_fetch: :string,
      ap_blocklist_audit_url: :string,
      theme_light: :string,
      theme_dark: :string
    }

    defaults = %{
      site_name: get_setting("site_name") || "",
      site_description: get_setting("site_description") || "",
      site_contact: get_setting("site_contact") || "",
      registration_mode: registration_mode(),
      registration_challenge_bits: Baudrate.Auth.Challenge.bits(),
      new_account_days: Baudrate.Auth.Trust.thresholds().days,
      new_account_posts: Baudrate.Auth.Trust.thresholds().posts,
      hold_first_posts: Baudrate.Moderation.HeldPosts.first_posts(),
      timezone: get_setting("timezone") || "Etc/UTC",
      ap_federation_enabled: get_setting("ap_federation_enabled") || "true",
      ap_federation_mode: get_setting("ap_federation_mode") || "blocklist",
      ap_domain_allowlist: get_setting("ap_domain_allowlist") || "",
      ap_authorized_fetch: get_setting("ap_authorized_fetch") || "false",
      ap_blocklist_audit_url: get_setting("ap_blocklist_audit_url") || "",
      theme_light: get_setting("theme_light") || @default_light_theme,
      theme_dark: get_setting("theme_dark") || @default_dark_theme
    }

    {defaults, types}
    |> Ecto.Changeset.cast(attrs, Map.keys(types))
    |> Ecto.Changeset.validate_required([:site_name, :registration_mode])
    |> Ecto.Changeset.validate_length(:site_name, min: 1, max: 255)
    # A sentence or two. It is the first thing a visitor reads and it is
    # rendered as plain text, so there is no reason for it to be long.
    |> Ecto.Changeset.validate_length(:site_description, max: 500)
    # How to reach whoever runs the site (7B): an address, a handle, a room.
    # One line of plain text — it is shown on the policy pages and in every
    # footer, so it is never markup and never a paragraph.
    |> Ecto.Changeset.validate_length(:site_contact, max: 200)
    |> Ecto.Changeset.validate_format(:site_contact, ~r/\A[^\r\n]*\z/,
      message: "must be a single line"
    )
    |> Ecto.Changeset.validate_inclusion(:registration_mode, @valid_registration_modes)
    # 0 switches the proof-of-work challenge off; above the cap a phone takes
    # long enough to give up, which would close the door rather than slow the
    # wave (see `Baudrate.Auth.Challenge`).
    |> Ecto.Changeset.validate_number(:registration_challenge_bits,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: Baudrate.Auth.Challenge.max_bits()
    )
    # How long, and how many posts, before an account outgrows the limits on
    # new accounts (ADR 0064). 0 and 0 trusts everyone.
    |> Ecto.Changeset.validate_number(:new_account_days,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: Baudrate.Auth.Trust.max_thresholds().days
    )
    |> Ecto.Changeset.validate_number(:new_account_posts,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: Baudrate.Auth.Trust.max_thresholds().posts
    )
    # How many of an account's first posts wait for a moderator (ADR 0065).
    # 0 turns it off.
    |> Ecto.Changeset.validate_number(:hold_first_posts,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: Baudrate.Moderation.HeldPosts.max_first_posts()
    )
    |> Ecto.Changeset.validate_inclusion(:ap_federation_enabled, ["true", "false"])
    |> Ecto.Changeset.validate_inclusion(:ap_federation_mode, @valid_federation_modes)
    |> Ecto.Changeset.validate_inclusion(:ap_authorized_fetch, ["true", "false"])
    |> Ecto.Changeset.validate_inclusion(:theme_light, @daisyui_theme_names)
    |> Ecto.Changeset.validate_inclusion(:theme_dark, @daisyui_theme_names)
    |> validate_timezone()
  end

  defp validate_timezone(changeset) do
    Ecto.Changeset.validate_change(changeset, :timezone, fn :timezone, tz ->
      if tz in Baudrate.Timezone.identifiers() do
        []
      else
        [timezone: "is not a valid IANA timezone"]
      end
    end)
  end

  @doc """
  How to reach whoever runs the site, as an admin wrote it on
  `/admin/settings` (7B), or `nil` when it is unset. Plain text, one line.
  """
  @spec site_contact() :: String.t() | nil
  def site_contact do
    case get_setting("site_contact") do
      contact when is_binary(contact) and contact != "" -> contact
      _ -> nil
    end
  end

  @doc """
  Validates and persists admin settings (including timezone).

  Returns `{:ok, changes}` on success or `{:error, changeset}` on validation failure.
  """
  @spec save_settings(map()) :: {:ok, map()} | {:error, Ecto.Changeset.t()}
  def save_settings(attrs) do
    changeset = change_settings(attrs)

    if changeset.valid? do
      changes = Ecto.Changeset.apply_changes(changeset)

      Repo.transaction(fn ->
        set_setting("site_name", changes.site_name)
        set_setting("site_description", changes.site_description || "")
        set_setting("site_contact", String.trim(changes.site_contact || ""))
        set_setting("registration_mode", changes.registration_mode)

        set_setting(
          "registration_challenge_bits",
          Integer.to_string(changes.registration_challenge_bits || 0)
        )

        set_setting("new_account_days", Integer.to_string(changes.new_account_days || 0))
        set_setting("new_account_posts", Integer.to_string(changes.new_account_posts || 0))
        set_setting("hold_first_posts", Integer.to_string(changes.hold_first_posts || 0))
        set_setting("timezone", changes.timezone || "Etc/UTC")
        set_setting("ap_federation_enabled", changes.ap_federation_enabled || "true")
        set_setting("ap_federation_mode", changes.ap_federation_mode || "blocklist")
        set_setting("ap_domain_allowlist", changes.ap_domain_allowlist || "")
        set_setting("ap_authorized_fetch", changes.ap_authorized_fetch || "false")
        set_setting("ap_blocklist_audit_url", changes.ap_blocklist_audit_url || "")
        set_setting("theme_light", changes.theme_light || @default_light_theme)
        set_setting("theme_dark", changes.theme_dark || @default_dark_theme)

        Baudrate.Setup.SettingsCache.refresh()

        changes
      end)
    else
      {:error, Map.put(changeset, :action, :validate)}
    end
  end

  @doc """
  Returns a changeset for tracking site name changes.
  """
  def change_site_name(attrs \\ %{}) do
    {%{}, %{site_name: :string}}
    |> Ecto.Changeset.cast(attrs, [:site_name])
    |> Ecto.Changeset.validate_required([:site_name])
    |> Ecto.Changeset.validate_length(:site_name, min: 1, max: 255)
  end

  @doc """
  Returns a changeset for tracking user registration changes.
  """
  def change_user_registration(user \\ %User{}, attrs \\ %{}) do
    User.registration_changeset(user, attrs)
  end

  @doc """
  Completes the setup by inserting site name, roles/permissions, admin user,
  and `setup_completed` flag in a single `Ecto.Multi` transaction.

  Steps executed atomically:

    1. Insert `site_name` setting
    2. Seed all roles and permissions via `seed_roles_and_permissions/0`
    3. Create the admin user with the `"admin"` role
    4. Insert `setup_completed = "true"` setting

  If any step fails, the entire transaction is rolled back.

  Refuses to run once setup has already been completed, returning
  `{:error, :setup, :already_completed, %{}}`. This is the context-boundary
  guard: the `EnsureSetup` plug only covers HTTP requests, so a LiveView
  session opened during the setup window must not be able to re-run the wizard
  and mint a second admin account afterwards.
  """
  @spec complete_setup(String.t(), map()) :: {:ok, map()} | {:error, term(), term(), map()}
  def complete_setup(site_name, user_attrs) do
    if setup_completed?() do
      {:error, :setup, :already_completed, %{}}
    else
      do_complete_setup(site_name, user_attrs)
    end
  end

  defp do_complete_setup(site_name, user_attrs) do
    result =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(
        :site_name,
        Setting.changeset(%Setting{}, %{key: "site_name", value: site_name})
      )
      |> Ecto.Multi.run(:seed_permissions, fn _repo, _changes ->
        seed_roles_and_permissions()
      end)
      |> Ecto.Multi.run(:admin_user, fn _repo, %{seed_permissions: %{roles: roles}} ->
        admin_role = Map.fetch!(roles, "admin")
        attrs = Map.put(user_attrs, "role_id", admin_role.id)
        %User{} |> User.registration_changeset(attrs) |> Repo.insert()
      end)
      |> Ecto.Multi.run(:recovery_codes, fn _repo, %{admin_user: admin_user} ->
        codes = Baudrate.Auth.generate_recovery_codes(admin_user)
        {:ok, codes}
      end)
      |> Ecto.Multi.run(:sysop_board, fn _repo, %{admin_user: admin_user} ->
        Content.seed_sysop_board(admin_user)
      end)
      |> Ecto.Multi.insert(
        :setup_completed,
        Setting.changeset(%Setting{}, %{key: "setup_completed", value: "true"})
      )
      |> Repo.transaction()

    case result do
      {:ok, _} -> Baudrate.Setup.SettingsCache.refresh()
      _ -> :ok
    end

    result
  end

  @doc """
  Seeds all roles, permissions, and role_permission join records into the database.

  Creates the four built-in roles (admin, moderator, user, guest), all
  permissions from `default_permissions/0`, and the join-table mappings.
  Higher roles include all permissions of lower roles — e.g., admin has
  every moderator, user, and guest permission.

  Returns `{:ok, %{roles: roles_map, permissions: permissions_list}}`.
  """
  def seed_roles_and_permissions do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    permissions_matrix = default_permissions()

    # Collect all unique permission names
    all_permission_names =
      permissions_matrix
      |> Map.values()
      |> List.flatten()
      |> Enum.uniq()

    # Seeding is idempotent. A migration that grants a newly introduced
    # permission (as ADR 0029's did) runs before first-run setup on a fresh
    # install, so seeding must be able to meet rows that already exist rather
    # than crash on the unique index.
    roles =
      permissions_matrix
      |> Map.keys()
      |> Enum.map(fn name ->
        %Role{}
        |> Role.changeset(%{name: name, description: Map.get(@role_descriptions, name)})
        |> Repo.insert!(on_conflict: :nothing, conflict_target: :name)
        |> reload_by_name(Role, name)
      end)
      |> Map.new(fn role -> {role.name, role} end)

    permissions =
      all_permission_names
      |> Enum.map(fn name ->
        %Permission{}
        |> Permission.changeset(%{
          name: name,
          description: Map.get(@permission_descriptions, name)
        })
        |> Repo.insert!(on_conflict: :nothing, conflict_target: :name)
        |> reload_by_name(Permission, name)
      end)

    permissions_by_name = Map.new(permissions, fn p -> {p.name, p} end)

    for {role_name, perm_names} <- permissions_matrix,
        perm_name <- perm_names do
      role = Map.fetch!(roles, role_name)
      permission = Map.fetch!(permissions_by_name, perm_name)

      Repo.insert!(
        %RolePermission{
          role_id: role.id,
          permission_id: permission.id,
          inserted_at: now,
          updated_at: now
        },
        on_conflict: :nothing
      )
    end

    {:ok, %{roles: roles, permissions: permissions}}
  end

  # `on_conflict: :nothing` returns a struct with a nil id when the row was
  # already there, so read the real one back.
  defp reload_by_name(%{id: nil}, schema, name), do: Repo.get_by!(schema, name: name)
  defp reload_by_name(record, _schema, _name), do: record

  @doc """
  Returns true if the given role has the given permission.
  Queries the database via the 3-table join.
  """
  @spec has_permission?(String.t(), String.t()) :: boolean()
  def has_permission?(role_name, permission_name) do
    query =
      from rp in RolePermission,
        join: r in Role,
        on: rp.role_id == r.id,
        join: p in Permission,
        on: rp.permission_id == p.id,
        where: r.name == ^role_name and p.name == ^permission_name,
        select: true

    Repo.exists?(query)
  end

  @doc """
  Returns a list of permission name strings for the given role name.
  """
  def permissions_for_role(role_name) do
    from(p in Permission,
      join: rp in RolePermission,
      on: rp.permission_id == p.id,
      join: r in Role,
      on: rp.role_id == r.id,
      where: r.name == ^role_name,
      select: p.name,
      order_by: p.name
    )
    |> Repo.all()
  end

  @doc """
  Returns all roles from the database.
  """
  def all_roles do
    Repo.all(from r in Role, order_by: r.name)
  end

  @doc """
  Returns the user IDs of all admin users.
  """
  def admin_user_ids do
    from(u in User, join: r in assoc(u, :role), where: r.name == "admin", select: u.id)
    |> Repo.all()
  end

  @doc """
  IDs of every admin and global moderator — the people who see every report
  (1B), as opposed to board moderators, who see their own boards'.
  """
  @spec staff_user_ids() :: [integer()]
  def staff_user_ids do
    from(u in User,
      join: r in assoc(u, :role),
      where: r.name in ["admin", "moderator"],
      select: u.id
    )
    |> Repo.all()
  end
end
