defmodule HllConditionalActions.Repo.Migrations.CreateRuleVersions do
  use Ecto.Migration

  # Who changed a rule, when, and what moved. A rule can ban people, so
  # "who wrote this and when" needs an answer that outlives the rule itself -
  # which is why the row keeps the rule's name and survives its deletion.
  def change do
    create table(:rule_versions) do
      add :rule_id, references(:rules, on_delete: :nilify_all)
      add :rule_name, :string, null: false
      add :user_id, references(:users, on_delete: :nilify_all)
      add :user_name, :string
      add :action, :string, null: false
      add :changes, :map, null: false, default: %{}

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:rule_versions, [:rule_id])
    create index(:rule_versions, [:inserted_at])
  end
end
