defmodule HllConditionalActions.Repo.Migrations.TicketFidelity do
  use Ecto.Migration

  # What the Caixa and the ticket settings show and did not store yet:
  #
  #   * categories get a colour and an order;
  #   * quick replies get a title and can close the ticket, and every answer
  #     remembers the quick reply it came from, so each one counts its uses;
  #   * office hours become ranges per weekday, several a day;
  #   * who may open a ticket (everyone, a minimum playtime, VIPs only), who
  #     never may (a CRCON flag, a recent ban), how many at once, whether a
  #     bare command asks for the reason, and whether case matters;
  #   * the warning before a silent ticket closes, which priorities mention
  #     the Discord roles, and what happens outside office hours;
  #   * on the ticket: the command it was opened with, the player it is
  #     about, when it was announced, whether it came in outside office
  #     hours and when the closing warning went out.
  #
  # A player may now keep more than one ticket open (`max_open_per_player`),
  # so the unique index that allowed one gives way to a plain one; opening is
  # serialised per player with an advisory lock instead.
  def up do
    alter table(:ticket_settings) do
      add :category_colors, :map, null: false, default: %{}
      add :category_order, {:array, :string}, null: false, default: []
      add :replies, {:array, :map}, null: false, default: []
      add :hours_ranges, :map, null: false, default: %{}
      add :warn_before_close, :boolean, null: false, default: false
      add :mention_min_priority, :string, null: false, default: "low"
      add :accept_offline, :boolean, null: false, default: true
      add :offline_alert_urgent, :boolean, null: false, default: true
      add :ignore_case, :boolean, null: false, default: true
      add :ask_reason, :boolean, null: false, default: false
      add :max_open_per_player, :integer, null: false, default: 1
      add :audience, :string, null: false, default: "all"
      add :min_playtime_hours, :integer, null: false, default: 2
      add :blocked_flags, {:array, :string}, null: false, default: []
      add :block_recent_bans, :boolean, null: false, default: false
    end

    execute("""
    UPDATE ticket_settings
       SET replies = ARRAY(
             SELECT jsonb_build_object('title', left(q, 40), 'body', q, 'closes', false)
               FROM unnest(quick_replies) AS q)
     WHERE cardinality(quick_replies) > 0
    """)

    alter table(:tickets) do
      add :opened_with, :string
      add :reported_player_id, :string
      add :reported_player_name, :string
      add :announced_at, :utc_datetime
      add :close_warned_at, :utc_datetime
      add :outside_hours, :boolean, null: false, default: false
    end

    drop_if_exists index(:tickets, [:server_id, :player_id], name: :tickets_one_open_per_player)
    create index(:tickets, [:server_id, :player_id, :status])
    create index(:tickets, [:reported_player_id])

    alter table(:ticket_messages) do
      add :quick_reply, :string
    end
  end

  def down do
    alter table(:ticket_messages) do
      remove :quick_reply
    end

    drop_if_exists index(:tickets, [:reported_player_id])
    drop_if_exists index(:tickets, [:server_id, :player_id, :status])

    create_if_not_exists unique_index(:tickets, [:server_id, :player_id],
                           where: "status <> 'closed'",
                           name: :tickets_one_open_per_player
                         )

    alter table(:tickets) do
      remove :opened_with
      remove :reported_player_id
      remove :reported_player_name
      remove :announced_at
      remove :close_warned_at
      remove :outside_hours
    end

    alter table(:ticket_settings) do
      remove :category_colors
      remove :category_order
      remove :replies
      remove :hours_ranges
      remove :warn_before_close
      remove :mention_min_priority
      remove :accept_offline
      remove :offline_alert_urgent
      remove :ignore_case
      remove :ask_reason
      remove :max_open_per_player
      remove :audience
      remove :min_playtime_hours
      remove :blocked_flags
      remove :block_recent_bans
    end
  end
end
