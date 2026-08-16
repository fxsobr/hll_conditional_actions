defmodule HllConditionalActions.Accounts.User do
  @moduledoc """
  Someone who can sign in.

  Accounts are created by an administrator rather than by self registration:
  this is an admin tool for a known group of people, so there is no signup
  flow and no email confirmation.

  Passwords are hashed with PBKDF2. `must_change_password?` is set on the
  bootstrap `admin` account and whenever an administrator resets a password, so
  the first thing that user does is choose their own.

  ## Two factor

  Optional, per account, and always TOTP - see
  `HllConditionalActions.Accounts.Totp`. Nothing forces it on, because an admin
  tool that locks out the one person holding the CRCON keys is worse than one
  guarded by a password alone.

  ## Server scope

  A user's role says *what* they may do; `servers` says *where*. An account
  with no servers assigned reaches every server, which is what a
  single-community install wants and means nothing has to be configured. Assign
  even one server and the account is restricted to exactly those - the shape a
  shared install with several clans needs.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias HllConditionalActions.Accounts.Role
  alias HllConditionalActions.Encrypted

  @type t :: %__MODULE__{}

  @derive {Inspect, except: [:password, :hashed_password, :totp_secret, :totp_recovery_codes]}
  schema "users" do
    field :username, :string
    field :name, :string
    field :email, :string
    field :hashed_password, :string, redact: true
    field :password, :string, virtual: true, redact: true
    field :password_confirmation, :string, virtual: true, redact: true
    field :active, :boolean, default: true
    field :must_change_password?, :boolean, source: :must_change_password, default: false
    field :last_login_at, :utc_datetime

    # ── Two factor ──────────────────────────────────────────────────────────
    #
    # The secret is encrypted at rest, like a CRCON key: anybody holding it can
    # produce this account's codes, which makes it as good as the password.
    # `totp_confirmed_at` is what turns the second factor on — a secret nobody
    # has proved their app can read is never asked for.
    field :totp_secret, Encrypted.Binary, redact: true
    field :totp_confirmed_at, :utc_datetime
    field :totp_last_step, :integer
    field :totp_recovery_codes, {:array, :string}, default: [], redact: true

    belongs_to :role, Role

    # Empty means "every server"; see the moduledoc.
    many_to_many :servers, HllConditionalActions.Servers.Server,
      join_through: "user_servers",
      on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for an administrator creating or editing a user.

  The password is optional here: leaving it blank on an edit keeps the current
  one.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(user, attrs) do
    user
    |> cast(attrs, [
      :username,
      :name,
      :email,
      :password,
      :password_confirmation,
      :active,
      :role_id,
      :must_change_password?
    ])
    |> validate_username()
    |> validate_email()
    |> validate_required([:role_id])
    |> maybe_put_password()
    |> assoc_constraint(:role)
  end

  @doc """
  Replaces the set of servers a user is restricted to.

  An empty list lifts the restriction entirely rather than locking the account
  out of everything - a user with a role but no reachable server would be a
  confusing dead end.
  """
  @spec servers_changeset(t(), [struct()]) :: Ecto.Changeset.t()
  def servers_changeset(user, servers) when is_list(servers) do
    user
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_assoc(:servers, servers)
  end

  @doc """
  Changeset for the bootstrap `admin` account created on a fresh database.

  The password rules are deliberately not applied: the whole point of that
  account is a memorable default (`admin` / `admin`) that the app then forces
  the operator to replace, and the length rule would reject it.
  """
  @spec bootstrap_changeset(t(), map()) :: Ecto.Changeset.t()
  def bootstrap_changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :name, :password, :role_id])
    |> validate_required([:username, :password, :role_id])
    |> put_change(:must_change_password?, true)
    |> put_password_hash()
    |> assoc_constraint(:role)
  end

  @doc """
  Changeset for a user changing their own password.
  """
  @spec password_changeset(t(), map()) :: Ecto.Changeset.t()
  def password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password, :password_confirmation])
    |> validate_required([:password])
    |> validate_password()
    |> put_password_hash()
    |> put_change(:must_change_password?, false)
  end

  @doc """
  Changeset for a user editing their own profile.
  """
  @spec profile_changeset(t(), map()) :: Ecto.Changeset.t()
  def profile_changeset(user, attrs) do
    user
    |> cast(attrs, [:name, :email])
    |> validate_email()
  end

  @doc """
  Records a successful sign in.
  """
  @spec login_changeset(t()) :: Ecto.Changeset.t()
  def login_changeset(user) do
    change(user, last_login_at: DateTime.utc_now() |> DateTime.truncate(:second))
  end

  @doc """
  Verifies a password against a user.

  Runs a dummy hash when the user is missing so that a wrong username and a
  wrong password take the same time to answer.
  """
  @spec valid_password?(t() | nil, String.t() | nil) :: boolean()
  def valid_password?(%__MODULE__{hashed_password: hashed}, password)
      when is_binary(hashed) and is_binary(password) and password != "" do
    Pbkdf2.verify_pass(password, hashed)
  end

  def valid_password?(_user, _password) do
    Pbkdf2.no_user_verify()
    false
  end

  defp validate_username(changeset) do
    changeset
    |> validate_required([:username])
    |> update_change(:username, &(&1 |> to_string() |> String.trim() |> String.downcase()))
    |> validate_length(:username, min: 3, max: 40)
    |> validate_format(:username, ~r/^[a-z0-9._-]+$/,
      message: "may only contain letters, numbers, dots, dashes and underscores"
    )
    |> unique_constraint(:username)
  end

  defp validate_email(changeset) do
    changeset
    |> update_change(:email, fn
      nil -> nil
      email -> email |> to_string() |> String.trim() |> String.downcase()
    end)
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+\.[^@,;\s]+$/,
      message: "must be a valid email address"
    )
    |> validate_length(:email, max: 160)
  end

  # Creating a user requires a password; editing one only sets it when a new
  # value was typed.
  defp maybe_put_password(changeset) do
    case {get_change(changeset, :password), get_field(changeset, :hashed_password)} do
      {nil, nil} -> validate_required(changeset, [:password])
      {nil, _existing} -> changeset
      {_password, _} -> changeset |> validate_password() |> put_password_hash()
    end
  end

  defp validate_password(changeset) do
    changeset
    |> validate_length(:password, min: 8, max: 72)
    |> validate_confirmation(:password, message: "does not match")
  end

  defp put_password_hash(changeset) do
    case get_change(changeset, :password) do
      nil ->
        changeset

      password ->
        changeset
        |> put_change(:hashed_password, Pbkdf2.hash_pwd_salt(password))
        |> delete_change(:password)
        |> delete_change(:password_confirmation)
    end
  end
end
