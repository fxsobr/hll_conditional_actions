defmodule HllConditionalActions.Repo.Migrations.VipShopImprovements do
  use Ecto.Migration

  # Password resets, coupons, gifts, highlighted packages, manual grants,
  # expiry reminders and the admin alert when a paid VIP cannot be granted.
  def change do
    create table(:vip_customer_tokens) do
      add :customer_id, references(:vip_customers, on_delete: :delete_all), null: false
      add :token_hash, :binary, null: false
      add :context, :string, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:vip_customer_tokens, [:token_hash])
    create index(:vip_customer_tokens, [:customer_id])

    create table(:vip_coupons) do
      add :code, :string, null: false
      add :kind, :string, null: false, default: "percent"
      add :value, :integer, null: false
      add :expires_at, :utc_datetime
      add :max_uses, :integer
      add :uses, :integer, null: false, default: 0
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:vip_coupons, ["upper(code)"], name: :vip_coupons_code_index)

    alter table(:vip_packages) do
      add :highlight, :string
      add :compare_at_cents, :integer
    end

    alter table(:vip_orders) do
      add :coupon_id, references(:vip_coupons, on_delete: :nilify_all)
      add :coupon_code, :string
      add :discount_cents, :integer, null: false, default: 0
      add :gift, :boolean, null: false, default: false
      add :granted_by, :string
    end

    alter table(:vip_grants) do
      add :reminded_at, :utc_datetime
    end

    alter table(:vip_shop_settings) do
      add :reminder_days, :integer, null: false, default: 3
      add :design, :map, null: false, default: %{}
      add :alert_webhook_id, references(:discord_webhooks, on_delete: :nilify_all)
    end
  end
end
