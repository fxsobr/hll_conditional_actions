defmodule HllConditionalActions.Repo.Migrations.SettingsAndAccess do
  use Ecto.Migration

  # Storage for the Ajustes area: the browsers a user is signed in on, a
  # second factor that was started but not finished, and a label for the
  # Discord channel a webhook posts to.
  def change do
    # One row per signed in browser. The cookie holds a random token; only its
    # hash is stored, so a leaked database cannot be replayed as a session.
    create table(:user_sessions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token_hash, :binary, null: false
      add :user_agent, :string
      add :ip, :string
      add :last_seen_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:user_sessions, [:token_hash])
    create index(:user_sessions, [:user_id])

    # A TOTP secret shown to its owner but not yet confirmed. Kept apart from
    # `users.totp_secret`, which is what turns the second factor on: a secret
    # here is never asked for at sign in.
    create table(:two_factor_enrolments) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :secret, :binary, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:two_factor_enrolments, [:user_id])

    # Discord does not tell a webhook which channel name it posts to, only
    # the id, so the staff writes it down.
    alter table(:discord_webhooks) do
      add :channel_label, :string
    end
  end
end
