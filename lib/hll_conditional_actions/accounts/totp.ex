defmodule HllConditionalActions.Accounts.Totp do
  @moduledoc """
  Time-based one time passwords (RFC 6238), the second factor for signing in.

  TOTP rather than email or SMS because this app sends neither: it has no
  mailer and no phone number for anybody. An authenticator app needs nothing
  from the server but a shared secret, which suits a tool a game community
  runs on one box.

  Implemented here rather than taken as a dependency because the whole
  algorithm is four lines over `:crypto` and `Base`, both of which ship with
  OTP — and a dependency for that would be one more thing to trust with the
  keys to every account.

  ## The shape of it

  A secret is 20 random bytes, shared once with the authenticator app as a
  base32 string (in a QR code, or typed in). Both sides then hash that secret
  together with the current 30 second step number; the first 6 digits of the
  result are the code. Nothing travels between them again.

  ## Drift

  Clocks disagree, and a person takes a moment to type. `valid?/3` therefore
  accepts the step before and after the current one, which is a 90 second
  window in total — the usual compromise, and why the caller must also refuse
  a code it has already seen (`Accounts` keeps the last accepted step).
  """

  import Bitwise, only: [&&&: 2]

  # 20 bytes is what RFC 4226 calls for and what every authenticator expects.
  @secret_bytes 20
  @digits 6
  @period_seconds 30
  # One step either side of now.
  @drift 1

  @type secret :: String.t()

  @doc """
  A fresh base32 secret, ready to be shown to an authenticator app.

  Unpadded, because the padding characters are noise in a QR code and several
  apps refuse them.
  """
  @spec generate_secret() :: secret()
  def generate_secret do
    @secret_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.encode32(padding: false)
  end

  @doc """
  The code for a secret at a point in time.

  Mostly useful for tests and for showing somebody what their app should be
  showing right now.

      iex> alias HllConditionalActions.Accounts.Totp
      iex> secret = Totp.generate_secret()
      iex> code = Totp.code(secret, 0)
      iex> String.length(code)
      6
  """
  @spec code(secret(), integer()) :: String.t() | :error
  def code(secret, at \\ nil) do
    case decode(secret) do
      {:ok, key} -> key |> hotp(step(at)) |> pad()
      :error -> :error
    end
  end

  @doc """
  Whether a code is right for a secret, allowing for clock drift.

  Returns the time step it matched, so the caller can refuse that same step
  later: a code is valid for 30 seconds, which is 30 seconds in which somebody
  watching over a shoulder could reuse it.

      iex> alias HllConditionalActions.Accounts.Totp
      iex> secret = Totp.generate_secret()
      iex> {:ok, _step} = Totp.verify(secret, Totp.code(secret))
      iex> Totp.verify(secret, "000000") in [:error, {:ok, 0}]
      true
  """
  @spec verify(secret(), String.t(), integer() | nil) :: {:ok, integer()} | :error
  def verify(secret, code, at \\ nil)

  def verify(secret, code, at) when is_binary(secret) and is_binary(code) do
    cleaned = String.replace(code, ~r/\s/, "")

    with true <- String.match?(cleaned, ~r/^\d{#{@digits}}$/),
         {:ok, key} <- decode(secret) do
      matching_step(key, cleaned, step(at))
    else
      _invalid -> :error
    end
  end

  def verify(_secret, _code, _at), do: :error

  # The clock the phone read may be a step either side of ours, so the codes
  # around `now` count too.
  defp matching_step(key, code, now) do
    Enum.reduce_while((now - @drift)..(now + @drift), :error, fn candidate, acc ->
      # Constant time: comparing with `==` leaks, through timing, how much of
      # the code was right, which is enough to guess one digit at a time.
      if secure_equal?(pad(hotp(key, candidate)), code) do
        {:halt, {:ok, candidate}}
      else
        {:cont, acc}
      end
    end)
  end

  @doc """
  The `otpauth://` URI an authenticator app reads out of the QR code.

  The issuer appears twice — in the label and as a parameter — because apps
  disagree about which one they read.
  """
  @spec provisioning_uri(secret(), String.t(), String.t()) :: String.t()
  def provisioning_uri(secret, account, issuer \\ "HLL Conditional Actions") do
    label = URI.encode("#{issuer}:#{account}")

    query =
      URI.encode_query(%{
        "secret" => secret,
        "issuer" => issuer,
        "algorithm" => "SHA1",
        "digits" => @digits,
        "period" => @period_seconds
      })

    "otpauth://totp/#{label}?#{query}"
  end

  @doc """
  The secret in groups of four, which is how it gets typed in by hand when a
  phone cannot scan the code.
  """
  @spec readable_secret(secret()) :: String.t()
  def readable_secret(secret) do
    secret
    |> String.graphemes()
    |> Enum.chunk_every(4)
    |> Enum.map_join(" ", &Enum.join/1)
  end

  @doc """
  How long the current code still has, in seconds. For the countdown on the
  enrolment screen.
  """
  @spec seconds_remaining(integer() | nil) :: pos_integer()
  def seconds_remaining(at \\ nil) do
    @period_seconds - rem(at || System.system_time(:second), @period_seconds)
  end

  # ── The algorithm ──────────────────────────────────────────────────────────

  defp step(nil), do: div(System.system_time(:second), @period_seconds)
  defp step(at), do: at

  defp decode(secret) when is_binary(secret) do
    # Authenticator apps show secrets in groups and in either case; accept
    # back whatever we showed.
    secret
    |> String.replace(~r/\s/, "")
    |> String.upcase()
    |> Base.decode32(padding: false)
  end

  defp decode(_secret), do: :error

  defp hotp(key, counter) do
    hash = :crypto.mac(:hmac, :sha, key, <<counter::unsigned-big-integer-size(64)>>)

    # RFC 4226 dynamic truncation: the low nibble of the last byte says where
    # in the hash to read the number from, so no fixed part of it is exposed.
    offset = :binary.last(hash) &&& 0x0F
    <<_skip::binary-size(^offset), _drop::1, truncated::31, _rest::binary>> = hash

    rem(truncated, 10 ** @digits)
  end

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(@digits, "0")

  defp secure_equal?(left, right) do
    :crypto.hash_equals(left, right)
  rescue
    # `hash_equals` insists both sides are the same size; a wrong length is a
    # wrong code, and saying so costs nothing an attacker did not already know.
    ArgumentError -> false
  end
end
