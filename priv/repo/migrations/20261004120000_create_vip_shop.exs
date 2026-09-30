defmodule HllConditionalActions.Repo.Migrations.CreateVipShop do
  use Ecto.Migration

  # The VIP shop: packages sold for one or more servers, the customers who buy
  # them (kept apart from the admin users), their orders and the VIP each
  # order granted on each server. Secrets - payment keys, the SMTP password,
  # the Discord client secret - are stored encrypted with the app's vault.
  def change do
    create table(:vip_shop_settings) do
      add :shop_title, :string
      add :shop_description, :text
      add :shop_subtitle, :string
      add :accent_color, :string, null: false, default: "#16a34a"
      add :logo_asset_id, :integer
      add :banner_asset_id, :integer
      add :social_links, :map, null: false, default: %{}
      add :footer_text, :text
      add :show_servers, :boolean, null: false, default: true
      add :currency, :string, null: false, default: "BRL"
      add :stacking, :string, null: false, default: "extend"
      add :password_login, :boolean, null: false, default: true
      add :discord_login, :boolean, null: false, default: false
      add :discord_client_id, :string
      add :discord_client_secret, :binary
      add :email_provider, :string, null: false, default: "smtp"
      add :email_api_key, :binary
      add :smtp_host, :string
      add :smtp_port, :integer
      add :smtp_username, :string
      add :smtp_password, :binary
      add :smtp_tls, :string, null: false, default: "starttls"
      add :mail_from_name, :string
      add :mail_from_address, :string
      add :email_templates, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    # Images uploaded for the storefront (logo, banner). Kept in the
    # database so they survive a container rebuild without a volume.
    create table(:vip_shop_assets) do
      add :kind, :string, null: false
      add :content_type, :string, null: false
      add :data, :binary, null: false
      add :byte_size, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create table(:vip_payment_providers) do
      add :provider, :string, null: false
      add :enabled, :boolean, null: false, default: false
      add :mode, :string, null: false, default: "test"
      add :credentials, :binary

      timestamps(type: :utc_datetime)
    end

    create unique_index(:vip_payment_providers, [:provider])

    create table(:vip_packages) do
      add :name, :string, null: false
      add :description, :text
      add :price_cents, :integer, null: false
      add :currency, :string, null: false
      add :duration_days, :integer
      add :active, :boolean, null: false, default: true
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create table(:vip_package_servers, primary_key: false) do
      add :package_id, references(:vip_packages, on_delete: :delete_all), null: false
      add :server_id, references(:servers, on_delete: :delete_all), null: false
    end

    create unique_index(:vip_package_servers, [:package_id, :server_id])

    create table(:vip_customers) do
      add :email, :string
      add :name, :string
      add :hashed_password, :string
      add :discord_id, :string
      add :discord_username, :string
      add :last_login_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:vip_customers, ["lower(email)"], name: :vip_customers_email_index)
    create unique_index(:vip_customers, [:discord_id])

    create table(:vip_customer_players) do
      add :customer_id, references(:vip_customers, on_delete: :delete_all), null: false
      add :player_id, :string, null: false
      add :player_name, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:vip_customer_players, [:customer_id, :player_id])

    create table(:vip_orders) do
      add :customer_id, references(:vip_customers, on_delete: :nilify_all)
      add :package_id, references(:vip_packages, on_delete: :nilify_all)
      add :package_name, :string, null: false
      add :player_id, :string, null: false
      add :player_name, :string
      add :amount_cents, :integer, null: false
      add :currency, :string, null: false
      add :duration_days, :integer
      add :provider, :string, null: false
      add :provider_ref, :string
      add :status, :string, null: false, default: "pending"
      add :paid_at, :utc_datetime
      add :fulfilled_at, :utc_datetime
      add :error, :text

      timestamps(type: :utc_datetime)
    end

    create index(:vip_orders, [:customer_id])
    create index(:vip_orders, [:status])
    create unique_index(:vip_orders, [:provider, :provider_ref])

    create table(:vip_grants) do
      add :order_id, references(:vip_orders, on_delete: :delete_all), null: false
      add :server_id, references(:servers, on_delete: :nilify_all)
      add :server_name, :string
      add :status, :string, null: false, default: "pending"
      add :expires_at, :utc_datetime
      add :error, :text

      timestamps(type: :utc_datetime)
    end

    create index(:vip_grants, [:order_id])
  end
end
