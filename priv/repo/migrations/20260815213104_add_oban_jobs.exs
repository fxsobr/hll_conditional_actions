defmodule HllConditionalActions.Repo.Migrations.AddObanJobs do
  use Ecto.Migration

  def up do
    Oban.Migration.up(version: 14)
  end

  # Rolling this back drops every queued job along with the tables.
  def down do
    Oban.Migration.down(version: 1)
  end
end
