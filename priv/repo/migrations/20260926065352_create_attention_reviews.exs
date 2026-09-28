defmodule HllConditionalActions.Repo.Migrations.CreateAttentionReviews do
  use Ecto.Migration

  def change do
    # An item of the attention inbox that an admin marked as handled. Items
    # are computed, not stored; this only remembers which ones are done, by
    # the key the item is computed with, and who handled it.
    create table(:attention_reviews) do
      add :key, :string, null: false
      add :user_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:attention_reviews, [:key])
  end
end
