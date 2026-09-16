defmodule Baudrate.Repo.Migrations.AddSanctionPermission do
  use Ecto.Migration

  # `moderator.sanction_user` is the authority to warn, silence and suspend an
  # account, and to refuse a pending registration (ADR 0029). Expressing it as
  # a permission keeps P1-D3 configuration rather than a hard-coded role name.
  #
  # Two permissions that enforce nothing go at the same time, because a listed
  # permission that enforces nothing is a false statement about who can do what
  # (ADR 0029). `moderator.mute_user` — muting became a member feature open to
  # everyone. `admin.view_dashboard` — there is no dashboard to gate, and the
  # /admin routes are gated by role. `admin.manage_roles` is kept and is now
  # checked in `Auth.update_user_role/3`.
  def up do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    execute("""
    INSERT INTO permissions (name, description, inserted_at, updated_at)
    VALUES ('moderator.sanction_user', 'Warn, silence and suspend accounts',
            '#{now}', '#{now}')
    ON CONFLICT (name) DO NOTHING
    """)

    execute("""
    INSERT INTO role_permissions (role_id, permission_id, inserted_at, updated_at)
    SELECT r.id, p.id, '#{now}', '#{now}'
    FROM roles r, permissions p
    WHERE r.name IN ('admin', 'moderator')
      AND p.name = 'moderator.sanction_user'
    ON CONFLICT DO NOTHING
    """)

    execute("""
    DELETE FROM role_permissions
    WHERE permission_id IN (
      SELECT id FROM permissions
      WHERE name IN ('moderator.mute_user', 'admin.view_dashboard')
    )
    """)

    execute("""
    DELETE FROM permissions
    WHERE name IN ('moderator.mute_user', 'admin.view_dashboard')
    """)
  end

  def down do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    execute("""
    INSERT INTO permissions (name, description, inserted_at, updated_at)
    VALUES ('moderator.mute_user', 'Mute users', '#{now}', '#{now}'),
           ('admin.view_dashboard', 'View admin dashboard', '#{now}', '#{now}')
    ON CONFLICT (name) DO NOTHING
    """)

    execute("""
    INSERT INTO role_permissions (role_id, permission_id, inserted_at, updated_at)
    SELECT r.id, p.id, '#{now}', '#{now}'
    FROM roles r, permissions p
    WHERE (r.name IN ('admin', 'moderator') AND p.name = 'moderator.mute_user')
       OR (r.name = 'admin' AND p.name = 'admin.view_dashboard')
    ON CONFLICT DO NOTHING
    """)

    execute("""
    DELETE FROM role_permissions
    WHERE permission_id IN (SELECT id FROM permissions WHERE name = 'moderator.sanction_user')
    """)

    execute("DELETE FROM permissions WHERE name = 'moderator.sanction_user'")
  end
end
