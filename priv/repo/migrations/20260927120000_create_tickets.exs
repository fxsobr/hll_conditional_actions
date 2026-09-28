defmodule HllConditionalActions.Repo.Migrations.CreateTickets do
  use Ecto.Migration

  # Players call an admin from the game chat; each call becomes a ticket that
  # admins answer from the web. See `HllConditionalActions.Tickets`.
  def up do
    # One row per server, created the first time somebody saves the settings.
    # No row means tickets are off for that server.
    create table(:ticket_settings) do
      add :server_id, references(:servers, on_delete: :delete_all), null: false
      add :enabled, :boolean, null: false, default: false
      add :commands, {:array, :string}, null: false, default: []
      add :cooldown_seconds, :integer, null: false, default: 60
      add :auto_close_hours, :integer, null: false, default: 12
      add :received_message, :text
      add :reply_prefix, :string
      add :closed_message, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:ticket_settings, [:server_id])

    create table(:tickets) do
      add :server_id, references(:servers, on_delete: :delete_all), null: false
      add :player_id, :string, null: false
      add :player_name, :string
      add :status, :string, null: false, default: "open"
      add :priority, :string, null: false, default: "normal"
      add :assigned_to_id, references(:users, on_delete: :nilify_all)
      add :closed_by_id, references(:users, on_delete: :nilify_all)
      add :close_reason, :string
      add :last_activity_at, :utc_datetime, null: false
      add :closed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:tickets, [:server_id, :status])
    create index(:tickets, [:status, :last_activity_at])
    create index(:tickets, [:player_id])

    # A player has at most one ticket open per server, so a follow-up line
    # always lands in the right one even if two listeners race.
    create unique_index(:tickets, [:server_id, :player_id],
             where: "status <> 'closed'",
             name: :tickets_one_open_per_player
           )

    create table(:ticket_messages) do
      add :ticket_id, references(:tickets, on_delete: :delete_all), null: false
      add :author, :string, null: false
      add :user_id, references(:users, on_delete: :nilify_all)
      add :body, :text, null: false
      # For messages sent to the player: whether CRCON accepted them.
      add :delivery, :string
      add :delivery_error, :string

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:ticket_messages, [:ticket_id, :inserted_at])

    # The built-in Administrator role holds every permission, but roles are
    # only written when missing, so the existing one has to be told about the
    # new pair.
    execute("""
    UPDATE roles
       SET permissions = permissions || ARRAY['view_tickets', 'manage_tickets']
     WHERE name = 'Administrator'
       AND NOT ('manage_tickets' = ANY(permissions))
    """)
  end

  def down do
    execute("""
    UPDATE roles
       SET permissions = array_remove(array_remove(permissions, 'view_tickets'), 'manage_tickets')
    """)

    drop table(:ticket_messages)
    drop table(:tickets)
    drop table(:ticket_settings)
  end
end
