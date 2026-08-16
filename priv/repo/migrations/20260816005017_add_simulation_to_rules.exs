defmodule HllConditionalActions.Repo.Migrations.AddSimulationToRules do
  use Ecto.Migration

  def change do
    # A rule in simulation is evaluated and recorded exactly as usual, but its
    # actions are described instead of sent to CRCON. It is how you build
    # confidence in a rule that kicks or bans before letting it loose.
    alter table(:rules) do
      add :simulation, :boolean, null: false, default: false
    end
  end
end
