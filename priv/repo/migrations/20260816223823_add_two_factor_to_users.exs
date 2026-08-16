defmodule HllConditionalActions.Repo.Migrations.AddTwoFactorToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # Encrypted with the same vault as the CRCON API keys: a secret in clear
      # text in a backup is a second factor anybody holding the backup can
      # produce codes for.
      add :totp_secret, :binary
      # Null until the person has proved their app works. An unconfirmed
      # secret is never asked for at sign in, so a half finished enrolment
      # cannot lock anybody out.
      add :totp_confirmed_at, :utc_datetime
      # The last time step accepted for this user. A TOTP code stays valid for
      # up to 90 seconds, which is 90 seconds in which a code read over a
      # shoulder would work a second time.
      add :totp_last_step, :bigint
      # One-way hashes, like passwords. Used up as they are spent.
      add :totp_recovery_codes, {:array, :string}, null: false, default: []
    end

    # "Who has two factor on" is a question the user list asks on every render.
    create index(:users, [:totp_confirmed_at])
  end
end
