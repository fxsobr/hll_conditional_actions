defmodule HllConditionalActions.Repo.Migrations.CategoryPriorities do
  use Ecto.Migration

  # Categories used to be "urgent or not". Each one now carries its own
  # priority (low, normal, high, urgent), and tickets without a category get
  # the server's default priority.
  def up do
    alter table(:ticket_settings) do
      add :category_priorities, :map, null: false, default: %{}
      add :default_priority, :string, null: false, default: "normal"
    end

    execute("""
    UPDATE ticket_settings
       SET category_priorities = COALESCE(
             (SELECT jsonb_object_agg(c,
                       CASE WHEN c = ANY(urgent_categories) THEN 'urgent' ELSE 'normal' END)
                FROM unnest(categories) AS c),
             '{}'::jsonb)
    """)

    alter table(:ticket_settings) do
      remove :categories
      remove :urgent_categories
    end
  end

  def down do
    alter table(:ticket_settings) do
      add :categories, {:array, :string}, null: false, default: []
      add :urgent_categories, {:array, :string}, null: false, default: []
    end

    execute("""
    UPDATE ticket_settings
       SET categories = ARRAY(SELECT jsonb_object_keys(category_priorities)),
           urgent_categories = ARRAY(SELECT key FROM jsonb_each_text(category_priorities)
                                      WHERE value = 'urgent')
    """)

    alter table(:ticket_settings) do
      remove :category_priorities
      remove :default_priority
    end
  end
end
