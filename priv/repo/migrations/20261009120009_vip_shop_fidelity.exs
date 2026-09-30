defmodule HllConditionalActions.Repo.Migrations.VipShopFidelity do
  use Ecto.Migration

  def change do
    # Who touched a package last, and packages retired without losing the
    # orders that point at them.
    alter table(:vip_packages) do
      add :updated_by, :string
      add :archived_at, :utc_datetime
    end

    # Coupons: a start date, a note for the team, the packages they are good
    # for (empty = every one), one use per customer, and who created them.
    alter table(:vip_coupons) do
      add :starts_at, :utc_datetime
      add :note, :string
      add :package_ids, {:array, :integer}, null: false, default: []
      add :once_per_customer, :boolean, null: false, default: false
      add :created_by, :string
    end

    # Orders: the servers of a manual grant (it has no package), why it was
    # given, when the receipt went out, and refunds.
    alter table(:vip_orders) do
      add :server_ids, {:array, :integer}, null: false, default: []
      add :reason, :text
      add :receipt_sent_at, :utc_datetime
      add :refunded_at, :utc_datetime
      add :refunded_by, :string
    end

    # The storefront is edited as a draft and published; the shop can be
    # closed to the public without uninstalling it.
    alter table(:vip_shop_settings) do
      add :design_draft, :map
      add :closed, :boolean, null: false, default: false
    end

    # Every webhook a payment provider sent, accepted or refused.
    create table(:vip_webhook_events) do
      add :provider, :string, null: false
      add :event, :string
      add :order_id, :integer
      add :ok, :boolean, null: false, default: true
      add :error, :string

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:vip_webhook_events, [:inserted_at])

    # Every email the shop tried to send.
    create table(:vip_email_log) do
      add :template, :string
      add :to, :string
      add :ok, :boolean, null: false, default: true
      add :error, :string
      add :duration_ms, :integer

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:vip_email_log, [:inserted_at])
  end
end
