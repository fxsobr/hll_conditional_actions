defmodule HllConditionalActions.Accounts.PasswordReset do
  @moduledoc """
  "Esqueci a senha" for the admin accounts: a link by e-mail that lets the
  owner of an account choose a new password.

  ## The link

  A `Phoenix.Token` signed with its own salt and good for 30 minutes. It
  carries the user id and a fingerprint of the account's current password
  hash (and e-mail), so it stops working the moment the password changes -
  a link that was already used, or one sent before somebody else reset the
  password, is dead without any table of spent tokens.

  ## What it never tells

  `request/3` answers the same whether or not an account has that address,
  and the page says the same thing either way. The only thing it admits is
  whether this install can send e-mail at all, which is about the install,
  not about anybody's account.

  ## Mail

  There is one mail server in the app: the one an administrator configures
  for the VIP shop (`HllConditionalActions.VipShop.Settings`). Without it
  there is no reset by e-mail; an administrator resets the password in
  Usuários instead.
  """

  import Ecto.Query

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Accounts.OwnPassword
  alias HllConditionalActions.Accounts.User
  alias HllConditionalActions.RateLimit
  alias HllConditionalActions.Repo
  alias HllConditionalActions.VipShop.Settings
  alias HllConditionalActions.Workers.SendPasswordResetEmail

  @salt "admin password reset v1"
  @max_age_seconds 30 * 60

  # A person asking again because the mail is slow is fine; somebody using
  # the form to flood an inbox is not. Past the limit nothing is sent, and
  # the page still says the same thing.
  @per_address [limit: 3, window_ms: 15 * 60 * 1000]

  @doc "How long a link stays valid, in minutes."
  @spec max_age_minutes() :: pos_integer()
  def max_age_minutes, do: div(@max_age_seconds, 60)

  @doc """
  Whether this install has a mail server to send the link through.

  Reads the settings row without creating it, so opening the form never
  writes to the database.
  """
  @spec mail_configured?() :: boolean()
  def mail_configured? do
    case Repo.one(from s in Settings, limit: 1) do
      nil -> false
      settings -> Settings.email_configured?(settings)
    end
  end

  @doc """
  Sends a reset link to every active account with `email`.

  `url_for` turns a token into the link to put in the e-mail; `locale` is
  the language to write it in. Returns `:not_configured` when there is no
  mail server, and `:ok` otherwise - whether or not anything was sent.
  """
  @spec request(String.t() | nil, (String.t() -> String.t()), String.t()) ::
          :ok | :not_configured
  def request(email, url_for, locale) when is_function(url_for, 1) do
    email = normalize(email)

    cond do
      not mail_configured?() ->
        :not_configured

      email == "" ->
        :ok

      RateLimit.check("reset:email:#{email}", @per_address) != :ok ->
        :ok

      true ->
        for user <- accounts_with(email) do
          %{"user_id" => user.id, "url" => url_for.(token(user)), "locale" => locale}
          |> SendPasswordResetEmail.new()
          |> Oban.insert!()
        end

        :ok
    end
  end

  @doc """
  A fresh reset token for `user`.

  `opts` go to `Phoenix.Token.sign/4` (`:signed_at`, for tests).
  """
  @spec token(User.t(), keyword()) :: String.t()
  def token(%User{} = user, opts \\ []) do
    Phoenix.Token.sign(
      HllConditionalActionsWeb.Endpoint,
      @salt,
      %{"u" => user.id, "f" => fingerprint(user)},
      Keyword.take(opts, [:signed_at])
    )
  end

  @doc """
  The account a token opens, while it is still good: signed by us, younger
  than 30 minutes, for an active account whose password has not changed
  since it was issued.
  """
  @spec verify(String.t() | nil) :: {:ok, User.t()} | :error
  def verify(token) when is_binary(token) and token != "" do
    with {:ok, %{"u" => id, "f" => print}} <-
           Phoenix.Token.verify(HllConditionalActionsWeb.Endpoint, @salt, token,
             max_age: @max_age_seconds
           ),
         %User{active: true} = user <- Accounts.get_user(id),
         true <- Plug.Crypto.secure_compare(fingerprint(user), print) do
      {:ok, user}
    else
      _invalid -> :error
    end
  end

  def verify(_token), do: :error

  @doc """
  Sets the new password from a reset link.

  Runs the same rules as any password its owner chooses, clears a forced
  change, and signs every session of the account out. The second factor is
  left alone: whoever holds the e-mail still needs the authenticator to get
  in.
  """
  @spec reset(String.t() | nil, map()) ::
          {:ok, User.t()} | {:error, :invalid_token} | {:error, Ecto.Changeset.t()}
  def reset(token, attrs) do
    case verify(token) do
      {:ok, user} ->
        case OwnPassword.update(user, attrs, current: false) do
          {:ok, user, _revoked} -> {:ok, user}
          {:error, changeset} -> {:error, changeset}
        end

      :error ->
        {:error, :invalid_token}
    end
  end

  @doc """
  An address with most of its first part hidden, for "we sent it to...".

      iex> HllConditionalActions.Accounts.PasswordReset.mask("marcelo@exemplo.com.br")
      "m•••••o@exemplo.com.br"
      iex> HllConditionalActions.Accounts.PasswordReset.mask("al@x.io")
      "a•••••@x.io"
  """
  @spec mask(String.t() | nil) :: String.t()
  def mask(email) do
    case String.split(normalize(email), "@", parts: 2) do
      [local, domain] when byte_size(local) > 2 ->
        String.first(local) <> "•••••" <> String.last(local) <> "@" <> domain

      [local, domain] when local != "" ->
        String.first(local) <> "•••••@" <> domain

      _other ->
        "•••••"
    end
  end

  @doc false
  @spec normalize(String.t() | nil) :: String.t()
  def normalize(email) when is_binary(email), do: email |> String.trim() |> String.downcase()
  def normalize(_email), do: ""

  defp accounts_with(email) do
    Repo.all(from u in User, where: u.email == ^email and u.active == true)
  end

  # Changes whenever the password (or the address the link went to) does.
  defp fingerprint(%User{hashed_password: hashed, email: email}) do
    :sha256
    |> :crypto.hash([to_string(hashed), 0, to_string(email)])
    |> binary_part(0, 16)
    |> Base.url_encode64(padding: false)
  end
end
