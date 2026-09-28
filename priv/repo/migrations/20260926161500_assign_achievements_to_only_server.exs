defmodule HllConditionalActions.Repo.Migrations.AssignAchievementsToOnlyServer do
  use Ecto.Migration

  # With a single server there is no doubt whose the existing achievements
  # are, so they become that server's. With several they stay shared, and
  # an administrator moves them.
  def up do
    execute """
    UPDATE achievements
    SET server_id = (SELECT min(id) FROM servers)
    WHERE server_id IS NULL AND (SELECT count(*) FROM servers) = 1
    """
  end

  def down, do: :ok
end
