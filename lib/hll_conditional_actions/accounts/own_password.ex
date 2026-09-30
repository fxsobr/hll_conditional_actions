defmodule HllConditionalActions.Accounts.OwnPassword do
  @moduledoc """
  Someone changing their own password.

  On top of `User.password_changeset/2` this applies the
  `PasswordPolicy`, can require the current password (the account page asks
  for it; the forced change right after signing in with a temporary one and
  the reset link do not), and signs out every other session of the account
  once the new password is saved - whoever knew the old one should not stay
  in.
  """

  alias HllConditionalActions.Accounts.PasswordPolicy
  alias HllConditionalActions.Accounts.Sessions
  alias HllConditionalActions.Accounts.User
  alias HllConditionalActions.Repo

  @doc """
  A changeset for the form, with the policy applied.

  With `current: true` the `current_password` param must match the stored
  password.
  """
  @spec changeset(User.t(), map(), keyword()) :: Ecto.Changeset.t()
  def changeset(%User{} = user, attrs, opts \\ []) do
    changeset =
      user
      |> User.password_changeset(attrs)
      |> PasswordPolicy.validate(user.username)

    if Keyword.get(opts, :current, false) do
      current = attrs["current_password"] || attrs[:current_password]

      if User.valid_password?(user, current) do
        changeset
      else
        Ecto.Changeset.add_error(changeset, :current_password, "is not right")
      end
    else
      changeset
    end
  end

  @doc """
  Saves the new password and signs out the other sessions.

  ## Options

    * `:current` - require and check `current_password` (default `false`)
    * `:keep_session_id` - the session asking, which stays signed in
  """
  @spec update(User.t(), map(), keyword()) ::
          {:ok, User.t(), [integer()]} | {:error, Ecto.Changeset.t()}
  def update(%User{} = user, attrs, opts \\ []) do
    case user |> changeset(attrs, opts) |> Repo.update() do
      {:ok, updated} ->
        revoked = Sessions.revoke_others(updated, Keyword.get(opts, :keep_session_id))
        {:ok, Repo.preload(updated, [:role, :servers], force: true), revoked}

      {:error, changeset} ->
        {:error, changeset}
    end
  end
end
