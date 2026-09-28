defmodule HllConditionalActions.Repo.Migrations.ExtendTickets do
  use Ecto.Migration

  def change do
    alter table(:ticket_settings) do
      # A ticket waiting this long on an admin shows in the attention inbox.
      add :attention_minutes, :integer, null: false, default: 5
      # At most this many tickets per player per hour; 0 means no limit.
      add :max_per_hour, :integer, null: false, default: 0
      add :quick_replies, {:array, :string}, null: false, default: []
      # Where a new ticket is announced on Discord, if anywhere.
      add :discord_webhook_id, references(:discord_webhooks, on_delete: :nilify_all)
      add :discord_mention_role_ids, :string
    end

    alter table(:tickets) do
      # :chat when a player called, :rule when a rule opened it.
      add :source, :string, null: false, default: "chat"
      add :rule_id, references(:rules, on_delete: :nilify_all)
      # When an admin first answered, for response-time metrics.
      add :first_response_at, :utc_datetime
    end

    alter table(:ticket_messages) do
      # The log line a player message came from, so a line the stream delivers
      # twice (it resumes after reconnecting) is only recorded once.
      add :log_key, :string
    end

    create unique_index(:ticket_messages, [:ticket_id, :log_key],
             where: "log_key IS NOT NULL",
             name: :ticket_messages_once_per_log_line
           )

    create index(:ticket_messages, [:log_key], where: "log_key IS NOT NULL")
    create index(:tickets, [:inserted_at])
  end
end
