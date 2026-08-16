defmodule HllConditionalActions.Accounts.TwoFactor do
  @moduledoc """
  Turning the second factor on and off, and checking it at sign in.

  `HllConditionalActions.Accounts.Totp` is the algorithm; this is the part
  that touches the database and decides what counts.

  ## Enrolling in two steps

  `start_enrolment/1` hands back a secret and shows it; nothing is stored
  until `confirm/2` is given a code that secret produces. That is deliberate:
  a secret saved before the person's app can read it would lock them out on
  their next sign in, and the account they would be locked out of is the one
  that holds the CRCON keys.

  ## What stops a stolen code

  A TOTP code is valid for up to 90 seconds here, counting drift. Every
  accepted code records its time step, and a step is never accepted twice for
  the same account — so a code read over a shoulder, or out of a proxy log, is
  spent the moment its owner uses it.

  ## Recovery codes

  Ten of them, shown once, stored only as PBKDF2 hashes — the same treatment
  as a password, because that is exactly what they are. Each works once. They
  exist for the phone that fell in a river; an administrator can also clear
  somebody's second factor entirely with `disable/1`, which is the escape
  hatch when the codes went down with the phone.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias HllConditionalActions.Accounts.Totp
  alias HllConditionalActions.Accounts.User
  alias HllConditionalActions.RateLimit
  alias HllConditionalActions.Repo

  # Ten wrong codes in fifteen minutes is far more than anybody types by
  # accident, and nowhere near enough to search a six digit space. Shared by
  # every place a code is checked — the sign in step and the account page —
  # so an attacker cannot spend a fresh budget by moving between them.
  @attempt_defaults [limit: 10, window_ms: 900_000]

  @recovery_code_count 10
  # Five bytes of randomness per code, shown as ten hex characters in two
  # groups. Short enough to read off paper, long enough that guessing one is
  # hopeless at the rate the sign in form allows.
  @recovery_code_bytes 5

  @doc """
  Whether this account is asked for a second factor at sign in.
  """
  @spec enabled?(User.t() | nil) :: boolean()
  def enabled?(%User{totp_confirmed_at: %DateTime{}}), do: true
  def enabled?(_user), do: false

  @doc """
  A secret to show, not yet stored.

  Returns the secret, the `otpauth://` URI and an SVG QR code, which is
  everything the enrolment screen needs.
  """
  @spec start_enrolment(User.t()) :: %{secret: String.t(), uri: String.t(), qr_svg: String.t()}
  def start_enrolment(%User{} = user) do
    secret = Totp.generate_secret()
    uri = Totp.provisioning_uri(secret, user.username)

    %{secret: secret, uri: uri, qr_svg: qr_svg(uri)}
  end

  @doc """
  Stores a secret once its owner has proved their app produces the same codes.

  Returns the recovery codes in clear text — the only time they exist in
  readable form, which is why the screen that gets them has to show them there
  and then.
  """
  @spec confirm(User.t(), String.t(), String.t()) ::
          {:ok, User.t(), [String.t()]} | {:error, :invalid_code}
  def confirm(%User{} = user, secret, code) do
    case Totp.verify(secret, code) do
      {:ok, step} ->
        codes = generate_recovery_codes()

        user =
          user
          |> change(%{
            totp_secret: secret,
            totp_confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second),
            totp_last_step: step,
            totp_recovery_codes: Enum.map(codes, &Pbkdf2.hash_pwd_salt/1)
          })
          |> Repo.update!()

        {:ok, user, codes}

      :error ->
        {:error, :invalid_code}
    end
  end

  @doc """
  Checks a code at sign in, refusing one that has already been used.

  Accepts either a six digit code from the app or one of the recovery codes;
  the caller does not have to know which the person typed, and neither does
  the person.
  """
  @spec verify(User.t(), String.t()) ::
          {:ok, User.t()} | {:ok, User.t(), :recovery_code_used} | {:error, :invalid_code}
  def verify(%User{} = user, code) do
    with :error <- verify_totp(user, code) do
      verify_recovery_code(user, code)
    end
  end

  defp verify_totp(%User{totp_secret: secret} = user, code) when is_binary(secret) do
    case Totp.verify(secret, code) do
      {:ok, step} ->
        # Replay: a code stays valid for a minute and a half, so the step it
        # belongs to is burned as soon as it is spent.
        if user.totp_last_step && step <= user.totp_last_step do
          :error
        else
          {:ok, user |> change(%{totp_last_step: step}) |> Repo.update!()}
        end

      :error ->
        :error
    end
  end

  defp verify_totp(_user, _code), do: :error

  defp verify_recovery_code(%User{totp_recovery_codes: hashes} = user, code)
       when is_list(hashes) and hashes != [] do
    cleaned = normalize_recovery_code(code)

    case Enum.find(hashes, &Pbkdf2.verify_pass(cleaned, &1)) do
      nil ->
        # Same work whether or not there were codes left, so the time taken
        # does not say which.
        Pbkdf2.no_user_verify()
        {:error, :invalid_code}

      spent ->
        user =
          user
          |> change(%{totp_recovery_codes: List.delete(hashes, spent)})
          |> Repo.update!()

        {:ok, user, :recovery_code_used}
    end
  end

  defp verify_recovery_code(_user, _code) do
    Pbkdf2.no_user_verify()
    {:error, :invalid_code}
  end

  @doc """
  The rate limit key for one account's code attempts.

  One key per account, shared by the sign in prompt and by the confirmations
  on the account page. A six digit code has a million values, of which about
  three are valid at any moment; without a shared counter, a script would walk
  that space by alternating between the two screens.
  """
  @spec attempt_key(User.t() | map() | nil) :: String.t()
  def attempt_key(nil), do: "2fa:unknown"
  def attempt_key(user), do: "2fa:user:#{user.id}"

  @doc """
  How many code attempts are allowed, and over what window.
  """
  @spec attempt_limits() :: keyword()
  def attempt_limits do
    Application.get_env(:hll_conditional_actions, :two_factor_rate_limit) || @attempt_defaults
  end

  @doc """
  Checks a code before a change to the second factor itself.

  Turning two factor off, or replacing the recovery codes, both weaken the
  account — so both ask for a code first. A session alone is not enough: a
  borrowed laptop or a stolen cookie would otherwise be able to remove the
  very thing standing in its way.

  Throttled on the same counter as the sign in prompt, and a recovery code
  spent here is spent for good, exactly as it would be at sign in.
  """
  @spec verify_step_up(User.t(), String.t()) ::
          {:ok, User.t()} | {:error, :invalid_code} | {:error, :rate_limited, pos_integer()}
  def verify_step_up(%User{} = user, code) do
    case RateLimit.peek(attempt_key(user), attempt_limits()) do
      {:error, :rate_limited, seconds} ->
        {:error, :rate_limited, seconds}

      :ok ->
        case verify(user, code) do
          {:ok, user} ->
            RateLimit.reset(attempt_key(user))
            {:ok, user}

          {:ok, user, :recovery_code_used} ->
            RateLimit.reset(attempt_key(user))
            {:ok, user}

          {:error, :invalid_code} ->
            RateLimit.check(attempt_key(user), attempt_limits())
            {:error, :invalid_code}
        end
    end
  end

  @doc """
  Turns the second factor off and forgets the secret.

  Used both by somebody switching it off for themselves and by an
  administrator rescuing an account whose phone is gone.
  """
  @spec disable(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def disable(%User{} = user) do
    user
    |> change(%{
      totp_secret: nil,
      totp_confirmed_at: nil,
      totp_last_step: nil,
      totp_recovery_codes: []
    })
    |> Repo.update()
  end

  @doc """
  Issues a fresh set of recovery codes, replacing whatever is left.
  """
  @spec regenerate_recovery_codes(User.t()) :: {:ok, User.t(), [String.t()]}
  def regenerate_recovery_codes(%User{} = user) do
    codes = generate_recovery_codes()

    user =
      user
      |> change(%{totp_recovery_codes: Enum.map(codes, &Pbkdf2.hash_pwd_salt/1)})
      |> Repo.update!()

    {:ok, user, codes}
  end

  @doc """
  How many recovery codes this account has left.
  """
  @spec recovery_codes_left(User.t()) :: non_neg_integer()
  def recovery_codes_left(%User{totp_recovery_codes: codes}) when is_list(codes),
    do: length(codes)

  def recovery_codes_left(_user), do: 0

  @doc """
  The ids of the users who have the second factor on, for the user list.
  """
  @spec enabled_user_ids() :: MapSet.t()
  def enabled_user_ids do
    User
    |> where([u], not is_nil(u.totp_confirmed_at))
    |> select([u], u.id)
    |> Repo.all()
    |> MapSet.new()
  end

  # ── Recovery codes ─────────────────────────────────────────────────────────

  defp generate_recovery_codes do
    for _each <- 1..@recovery_code_count do
      @recovery_code_bytes
      |> :crypto.strong_rand_bytes()
      |> Base.encode16(case: :lower)
      |> format_recovery_code()
    end
  end

  # "a1b2c-3d4e5" reads back off paper more reliably than ten unbroken
  # characters do.
  defp format_recovery_code(hex) do
    String.slice(hex, 0, 5) <> "-" <> String.slice(hex, 5, 5)
  end

  # Typed back in, the dash and the case are noise.
  defp normalize_recovery_code(code) do
    code
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-f0-9]/, "")
    |> format_recovery_code()
  end

  # ── The QR code ────────────────────────────────────────────────────────────

  defp qr_svg(uri) do
    uri
    |> EQRCode.encode()
    |> EQRCode.svg(width: 200, background_color: "#ffffff", color: "#000000")
  end
end
