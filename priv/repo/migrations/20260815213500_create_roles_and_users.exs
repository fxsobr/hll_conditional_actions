defmodule HllConditionalActions.Repo.Migrations.CreateRolesAndUsers do
  use Ecto.Migration

  def change do
    create table(:roles) do
      add :name, :string, size: 60, null: false
      add :description, :text
      # Permission names are validated in code against a fixed catalog, so a
      # plain array keeps role editing to a single update.
      add :permissions, {:array, :string}, null: false, default: []
      add :system, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:roles, [:name])

    create table(:users) do
      add :username, :string, size: 40, null: false
      add :name, :string
      add :email, :string, size: 160
      add :hashed_password, :string, null: false
      add :active, :boolean, null: false, default: true
      add :must_change_password, :boolean, null: false, default: false
      add :last_login_at, :utc_datetime
      # Deleting a role in use would leave users without permissions, so the
      # database refuses it and the UI asks for a replacement first.
      add :role_id, references(:roles, on_delete: :restrict), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:username])
    create index(:users, [:role_id])
  end
end
