defmodule HllConditionalActions.Repo.Migrations.GrantManagePlayers do
  use Ecto.Migration

  # Acting on a player (message, punish, kick, ban, watchlist, VIP) used to
  # ride on `manage_tickets`. It has its own permission now, so every role
  # that could answer tickets keeps acting on players - system or custom.
  def up do
    execute("""
    UPDATE roles
    SET permissions = array_append(permissions, 'manage_players')
    WHERE 'manage_tickets' = ANY(permissions)
      AND NOT ('manage_players' = ANY(permissions))
    """)
  end

  def down do
    execute("""
    UPDATE roles
    SET permissions = array_remove(permissions, 'manage_players')
    WHERE 'manage_players' = ANY(permissions)
    """)
  end
end
