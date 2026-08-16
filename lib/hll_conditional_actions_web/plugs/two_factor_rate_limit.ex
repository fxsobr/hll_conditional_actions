defmodule HllConditionalActionsWeb.Plugs.TwoFactorRateLimit do
  @moduledoc """
  Counts wrong codes at the second step, and stops answering after a few.

  This limit matters more than the one on the password form. A password has a
  large space; a TOTP code has a million, of which about three are valid at any
  moment because of the drift window. Left unlimited, a script would walk that
  space in minutes and the second factor would be decoration.

  Counted per account rather than per address, because the account is already
  known by the time this runs: the session says whose password was accepted.
  Wrong codes are counted, right ones are not — a person mistyping twice and
  then getting it right walks away with a clean slate.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [render: 3, put_view: 2]

  use Gettext, backend: HllConditionalActionsWeb.Gettext

  alias HllConditionalActions.Accounts.TwoFactor
  alias HllConditionalActions.RateLimit

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: "POST"} = conn, _opts) do
    user = conn.assigns[:pending_user]

    case RateLimit.peek(key(user), limits()) do
      :ok -> conn
      {:error, :rate_limited, seconds} -> refuse(conn, seconds, user)
    end
  end

  def call(conn, _opts), do: conn

  @doc """
  Records a wrong code.

  Called by the controller rather than counted in `call/2`, so that a person
  who types the right code first time never spends anything.
  """
  @spec failed(Plug.Conn.t(), map()) :: :ok
  def failed(_conn, user) do
    RateLimit.check(key(user), limits())

    :ok
  end

  @doc """
  Clears the count after a code is accepted.
  """
  @spec succeeded(Plug.Conn.t(), map()) :: :ok
  def succeeded(_conn, user), do: RateLimit.reset(key(user))

  # The counter is shared with the account page, which asks for a code before
  # letting anybody weaken the second factor.
  defp key(user), do: TwoFactor.attempt_key(user)
  defp limits, do: TwoFactor.attempt_limits()

  defp refuse(conn, seconds, user) do
    conn
    |> put_resp_header("retry-after", to_string(seconds))
    |> put_status(:too_many_requests)
    |> put_view(html: HllConditionalActionsWeb.TwoFactorHTML)
    |> render(:new,
      error:
        gettext("Too many wrong codes. Try again in %{seconds} seconds.",
          seconds: seconds
        ),
      recovery_codes_left: TwoFactor.recovery_codes_left(user)
    )
    |> halt()
  end
end
