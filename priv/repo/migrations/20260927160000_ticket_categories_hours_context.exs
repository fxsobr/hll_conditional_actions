defmodule HllConditionalActions.Repo.Migrations.TicketCategoriesHoursContext do
  use Ecto.Migration

  def change do
    alter table(:ticket_settings) do
      # `!admin cheat ...`: the first word, when it is one of these, becomes
      # the ticket's category; the urgent ones open as urgent.
      add :categories, {:array, :string}, null: false, default: []
      add :urgent_categories, {:array, :string}, null: false, default: []
      # `!admin status` and `!admin close`, in the community's language.
      add :status_word, :string
      add :close_word, :string
      # Office hours, in the server's time zone. Outside them the player is
      # told nobody is around, and the ticket waits.
      add :hours_enabled, :boolean, null: false, default: false
      add :hours_start, :time
      add :hours_end, :time
      add :hours_days, {:array, :integer}, null: false, default: [1, 2, 3, 4, 5, 6, 7]
      add :offline_message, :text
    end

    alter table(:tickets) do
      add :category, :string
      # What happened around the player before they called: recent chat,
      # their kills and team kills. Captured once, when the ticket opens.
      add :context, {:array, :map}, null: false, default: []
    end

    create index(:tickets, [:category])
  end
end
