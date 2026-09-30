defmodule HllConditionalActions.Accounts.PasswordPolicy do
  @moduledoc """
  The rules a password chosen by its owner has to meet.

  Applied on top of `User.password_changeset/2` wherever people pick their own
  password (the account page, the forced change after the first sign in, the
  reset link). An administrator setting a temporary password in Usuários is
  not held to it: that password has to be replaced at the next sign in anyway.

  `checks/3` returns the same rules as a list, so a form can tick them off as
  the person types.
  """

  import Ecto.Changeset

  @min_length 12
  @max_length 72

  @doc "The shortest password accepted."
  @spec min_length() :: pos_integer()
  def min_length, do: @min_length

  @doc """
  Adds the policy's errors to a password changeset.
  """
  @spec validate(Ecto.Changeset.t(), String.t() | nil) :: Ecto.Changeset.t()
  def validate(changeset, username) do
    changeset
    |> validate_length(:password, min: @min_length, max: @max_length)
    |> validate_change(:password, fn :password, password ->
      cond do
        common?(password, username) ->
          [password: "must not be admin or your username"]

        not (letters?(password) and digits?(password)) ->
          [password: "must mix letters and numbers"]

        true ->
          []
      end
    end)
  end

  @doc """
  Each rule with whether `password` meets it, for a live checklist.

  Returns `{key, met?}` pairs; `:symbol` is advice, not a requirement.
  """
  @spec checks(String.t(), String.t(), String.t() | nil) :: [{atom(), boolean()}]
  def checks(password, confirmation, username) do
    password = password || ""

    [
      length: String.length(password) >= @min_length and String.length(password) <= @max_length,
      not_common: password != "" and not common?(password, username),
      letters_and_digits: letters?(password) and digits?(password),
      symbol: symbol?(password),
      match: password != "" and password == confirmation
    ]
  end

  @doc """
  0 to 4: how many bars a strength meter lights for `password`.
  """
  @spec strength(String.t() | nil, String.t() | nil) :: 0..4
  def strength(nil, _username), do: 0
  def strength("", _username), do: 0

  def strength(password, username) do
    cond do
      String.length(password) < @min_length or common?(password, username) ->
        1

      not (letters?(password) and digits?(password)) ->
        2

      symbol?(password) or String.length(password) >= 16 ->
        4

      true ->
        3
    end
  end

  defp common?(password, username) do
    lowered = String.downcase(password)

    lowered in ["admin", "password", "senha"] or
      (is_binary(username) and lowered == String.downcase(username))
  end

  defp letters?(password), do: password =~ ~r/\p{L}/u
  defp digits?(password), do: password =~ ~r/\d/
  defp symbol?(password), do: password =~ ~r/[^\p{L}\d\s]/u
end
