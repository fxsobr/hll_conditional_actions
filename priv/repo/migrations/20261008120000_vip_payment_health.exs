defmodule HllConditionalActions.Repo.Migrations.VipPaymentHealth do
  use Ecto.Migration

  def change do
    # What the admin sees about each payment method: whether its keys worked
    # the last time they were tried, and what its webhook last did.
    alter table(:vip_payment_providers) do
      add :checked_at, :utc_datetime
      add :check_error, :string
      add :last_webhook_at, :utc_datetime
      add :last_webhook_event, :string
      add :last_webhook_error_at, :utc_datetime
      add :last_webhook_error, :string
    end

    # A purchase an admin makes to try a payment method: no customer, no
    # package, never delivered and never counted as revenue.
    alter table(:vip_orders) do
      add :test, :boolean, null: false, default: false
    end
  end
end
