defmodule HllConditionalActions.Repo.Migrations.ShopStorefront do
  use Ecto.Migration

  def change do
    # The message a buyer leaves for the player who gets a gift, and when it
    # reached them in the game.
    create table(:vip_order_notes) do
      add :order_id, references(:vip_orders, on_delete: :delete_all), null: false
      add :message, :string, size: 80, null: false
      add :delivered_at, :utc_datetime
      add :delivered_server, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:vip_order_notes, [:order_id])

    # Which emails a customer wants: the reminder before a VIP ends and the
    # receipt of a purchase. No row means both.
    create table(:vip_customer_preferences) do
      add :customer_id, references(:vip_customers, on_delete: :delete_all), null: false
      add :expiry_reminders, :boolean, null: false, default: true
      add :receipts, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:vip_customer_preferences, [:customer_id])
  end
end
