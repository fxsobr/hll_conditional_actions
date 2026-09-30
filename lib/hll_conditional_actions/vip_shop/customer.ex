defmodule HllConditionalActions.VipShop.Customer do
  @moduledoc """
  Somebody who buys VIP in the shop.

  Kept apart from `HllConditionalActions.Accounts.User`, which is staff with
  roles and server scope: a customer can do nothing in the admin, and an
  admin account is never a shop login. A customer signs in with email and
  password, with Discord, or both.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias HllConditionalActions.VipShop.CustomerPlayer

  @type t :: %__MODULE__{}

  schema "vip_customers" do
    field :email, :string
    field :name, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :discord_id, :string
    field :discord_username, :string
    field :last_login_at, :utc_datetime

    has_many :players, CustomerPlayer

    timestamps(type: :utc_datetime)
  end

  @doc """
  A new account with email and password.
  """
  def registration_changeset(customer, attrs) do
    customer
    |> cast(attrs, [:name, :email, :password])
    |> validate_required([:name, :email, :password])
    |> validate_email()
    |> validate_length(:name, max: 80)
    |> validate_length(:password, min: 10, max: 72)
    |> hash_password()
  end

  @doc """
  A new password, from the reset form. Also works for an account created with
  Discord, which then gains a password too.
  """
  def password_changeset(customer, attrs) do
    customer
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_length(:password, min: 10, max: 72)
    |> validate_confirmation(:password, message: "does not match")
    |> hash_password()
  end

  @doc """
  An account created or updated from a Discord sign in.
  """
  def discord_changeset(customer, attrs) do
    customer
    |> cast(attrs, [:name, :email, :discord_id, :discord_username])
    |> validate_required([:discord_id])
    |> update_change(:email, &normalize_email/1)
    |> unique_constraint(:discord_id)
    |> unique_constraint(:email, name: :vip_customers_email_index)
  end

  @doc "Whether a password matches, spending the same time when it does not."
  @spec valid_password?(t() | nil, String.t()) :: boolean()
  def valid_password?(%__MODULE__{hashed_password: hash}, password)
      when is_binary(hash) and is_binary(password),
      do: Pbkdf2.verify_pass(password, hash)

  def valid_password?(_customer, _password) do
    Pbkdf2.no_user_verify()
    false
  end

  defp validate_email(changeset) do
    changeset
    |> update_change(:email, &normalize_email/1)
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, message: "must be a valid email")
    |> validate_length(:email, max: 160)
    |> unique_constraint(:email, name: :vip_customers_email_index)
  end

  defp hash_password(changeset) do
    case get_change(changeset, :password) do
      nil ->
        changeset

      password when changeset.valid? ->
        put_change(changeset, :hashed_password, Pbkdf2.hash_pwd_salt(password))

      _invalid ->
        changeset
    end
  end

  defp normalize_email(nil), do: nil
  defp normalize_email(email), do: email |> String.trim() |> String.downcase()
end
