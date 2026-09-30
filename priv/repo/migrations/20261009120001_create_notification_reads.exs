defmodule HllConditionalActions.Repo.Migrations.CreateNotificationReads do
  use Ecto.Migration

  # What each user already saw in the bell's panel. Notifications are
  # computed (see HllConditionalActions.Notifications), so only the fact that
  # one was read is stored, under the same kind of key the attention inbox
  # uses: a new occurrence gets a new key and shows up unread again.
  def change do
    create table(:notification_reads) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :key, :string, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:notification_reads, [:user_id, :key])
  end
end
