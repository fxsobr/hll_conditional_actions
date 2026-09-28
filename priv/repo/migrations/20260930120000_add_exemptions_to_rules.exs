defmodule HllConditionalActions.Repo.Migrations.AddExemptionsToRules do
  use Ecto.Migration

  def change do
    alter table(:rules) do
      # Players the rule never applies to; see Rules.Exemptions.
      add :exemptions, :map, null: false, default: %{}
    end
  end
end
