defmodule HllConditionalActions.Repo.Migrations.CreateDiscordWebhooks do
  use Ecto.Migration

  # Rules used to carry the webhook URL - a secret - inside their actions.
  # From here on they point at a row of `discord_webhooks`, where the URL is
  # encrypted. Existing rules are moved over at boot by
  # `HllConditionalActions.Discord.adopt_legacy_urls/0`, because encrypting
  # needs the vault, which migrations do not start.
  def change do
    create table(:discord_webhooks) do
      add :name, :string, null: false
      add :url, :binary, null: false
      add :username, :string
      add :avatar_url, :string
      # What Discord said about the webhook the last time it was checked.
      add :remote_name, :string
      add :channel_id, :string
      add :guild_id, :string
      add :last_error, :string
      add :last_error_at, :utc_datetime
      add :last_delivered_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:discord_webhooks, [:name])

    # Messages a rule edits instead of posting anew, and the forum threads it
    # created, keyed by what the rule rendered as the key.
    create table(:discord_messages) do
      add :webhook_id, references(:discord_webhooks, on_delete: :delete_all), null: false
      add :key, :string, null: false
      add :message_id, :string
      add :thread_id, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:discord_messages, [:webhook_id, :key])

    # Delivery outcome of the queued actions, by action index. Kept apart from
    # `results` because the job can finish before the engine stores those.
    alter table(:rule_executions) do
      add :deliveries, :map, null: false, default: %{}
    end
  end
end
