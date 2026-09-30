defmodule HllConditionalActions.Accounts.Enrolments do
  @moduledoc """
  Second factors in the middle of being set up.

  `start/1` returns the same secret until it is confirmed or cancelled, so the
  QR code scanned yesterday still matches today. Confirming goes through
  `HllConditionalActions.Accounts.TwoFactor.confirm/3` as before, followed by
  `clear/1`.
  """

  import Ecto.Query

  alias HllConditionalActions.Accounts.Totp
  alias HllConditionalActions.Accounts.TwoFactorEnrolment
  alias HllConditionalActions.Accounts.User
  alias HllConditionalActions.Repo

  @doc "The unconfirmed enrolment of a user, if any."
  @spec pending(User.t()) :: TwoFactorEnrolment.t() | nil
  def pending(%User{id: id}), do: Repo.get_by(TwoFactorEnrolment, user_id: id)

  @doc """
  The secret to show: the pending one, or a fresh one that is stored as
  pending.
  """
  @spec start(User.t()) :: TwoFactorEnrolment.t()
  def start(%User{} = user) do
    case pending(user) do
      nil ->
        Repo.insert!(%TwoFactorEnrolment{user_id: user.id, secret: Totp.generate_secret()},
          on_conflict: :nothing,
          conflict_target: :user_id
        )

        pending(user)

      enrolment ->
        enrolment
    end
  end

  @doc """
  What the setup screen shows for a secret: the `otpauth://` URI, its QR code
  as SVG and the secret in groups of four for typing by hand.
  """
  @spec display(User.t(), String.t()) :: %{
          uri: String.t(),
          qr_svg: String.t(),
          readable: String.t()
        }
  def display(%User{} = user, secret) do
    uri = Totp.provisioning_uri(secret, user.username)

    qr_svg =
      uri
      |> EQRCode.encode()
      |> EQRCode.svg(width: 200, background_color: "#ffffff", color: "#000000")

    %{uri: uri, qr_svg: qr_svg, readable: Totp.readable_secret(secret)}
  end

  @doc "Forgets a pending enrolment (confirmed, cancelled or reset)."
  @spec clear(User.t()) :: :ok
  def clear(%User{id: id}) do
    Repo.delete_all(from e in TwoFactorEnrolment, where: e.user_id == ^id)
    :ok
  end

  @doc """
  Checks a code against a pending secret without storing anything: step 2 of
  the setup, "prove the QR code was read". Returns the time step it matched,
  which `activate/4` records so the same code cannot sign in afterwards.
  """
  @spec check_code(String.t(), String.t()) :: {:ok, integer()} | :error
  def check_code(secret, code) when is_binary(secret) and is_binary(code) do
    Totp.verify(secret, code |> String.replace(~r/\s/, ""))
  end

  def check_code(_secret, _code), do: :error

  @doc """
  Ten fresh recovery codes, in clear, to show once. They only start working
  when `activate/4` stores them.
  """
  @spec new_recovery_codes() :: [String.t()]
  def new_recovery_codes do
    for _each <- 1..10 do
      hex = 5 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
      String.slice(hex, 0, 5) <> "-" <> String.slice(hex, 5, 5)
    end
  end

  @doc """
  Turns the second factor on once its owner has saved the recovery codes:
  stores the secret, the step of the code they typed and the hashed codes,
  and forgets the pending enrolment. The last step of the setup; the same
  row `TwoFactor.confirm/3` writes.
  """
  @spec activate(User.t(), String.t(), integer(), [String.t()]) :: {:ok, User.t()}
  def activate(%User{} = user, secret, step, codes) do
    user =
      user
      |> Ecto.Changeset.change(%{
        totp_secret: secret,
        totp_confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        totp_last_step: step,
        totp_recovery_codes: Enum.map(codes, &Pbkdf2.hash_pwd_salt/1)
      })
      |> Repo.update!()

    clear(user)
    {:ok, user}
  end

  @doc "When each user with a pending enrolment started it, by user id."
  @spec pending_since() :: %{integer() => DateTime.t()}
  def pending_since do
    from(e in TwoFactorEnrolment, select: {e.user_id, e.inserted_at})
    |> Repo.all()
    |> Map.new()
  end
end
