defmodule HllConditionalActions.Repo.Migrations.AddServerToAchievements do
  use Ecto.Migration

  def change do
    # Achievements belong to a server, like its seasons and its players'
    # career totals: each community sets its own goals and rewards. Existing
    # rows keep a null server and stay valid on every server, so nothing a
    # player already unlocked is lost.
    alter table(:achievements) do
      add :server_id, references(:servers, on_delete: :delete_all)
    end

    create index(:achievements, [:server_id])
  end
end
