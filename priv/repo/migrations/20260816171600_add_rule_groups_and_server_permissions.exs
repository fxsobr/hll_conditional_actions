defmodule HllConditionalActions.Repo.Migrations.AddRuleGroupsAndServerPermissions do
  use Ecto.Migration

  def change do
    # Rules grow past the point where one flat list is navigable; a group is a
    # free-text folder ("Anti-toxicity", "Seeding") an admin can also enable or
    # disable as a unit.
    alter table(:rules) do
      add :group, :string
    end

    create index(:rules, [:group])

    # The permissions the server's API key was last seen to hold. Stored so a
    # rule can warn "this action will never work with this key" without a
    # CRCON round trip on every page load.
    alter table(:servers) do
      add :known_permissions, {:array, :string}, null: false, default: []
      add :permissions_checked_at, :utc_datetime
    end
  end
end
