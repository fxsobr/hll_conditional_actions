defmodule HllConditionalActions.Repo.Migrations.AddRuleDraftsAndSnapshots do
  use Ecto.Migration

  # A live rule is edited as a draft that the engine never sees until it is
  # published, and every version keeps the full definition so it can be
  # restored. Existing versions keep a null snapshot: they still show their
  # field diff, they just cannot be restored.
  def change do
    alter table(:rules) do
      add :draft, :map
      add :draft_user_name, :string
      add :draft_updated_at, :utc_datetime
    end

    alter table(:rule_versions) do
      add :snapshot, :map
    end
  end
end
