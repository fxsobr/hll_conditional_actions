defmodule HllConditionalActions.Accounts.TwoFactorEnrolment do
  @moduledoc """
  A second factor someone started to set up and has not confirmed yet.

  Holding the secret here, instead of only in the page that showed it, lets
  the setup be picked up again after a reload ("Continuar") and lets the
  people pages say "em configuração". It is never asked for at sign in: only
  `users.totp_secret`, written by `TwoFactor.confirm/3`, is.
  """

  use Ecto.Schema

  alias HllConditionalActions.Accounts.User
  alias HllConditionalActions.Encrypted

  @type t :: %__MODULE__{}

  schema "two_factor_enrolments" do
    field :secret, Encrypted.Binary, redact: true

    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end
end
