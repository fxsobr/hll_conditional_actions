defmodule HllConditionalActionsWeb.TwoFactorController do
  @moduledoc """
  The second step of signing in: the code from the authenticator app.

  Reached only with a session that has already passed the password, and
  reachable for five minutes. Until a code is accepted the visitor is not
  signed in at all — the session holds a "pending" id that no other page reads,
  so there is no window in which a half authenticated browser can see anything.

  A plain controller for the same reason the password form is one: signing in
  writes a cookie, and that needs a real HTTP response.
  """

  use HllConditionalActionsWeb, :controller

  alias HllConditionalActions.Accounts.TwoFactor
  alias HllConditionalActionsWeb.Plugs
  alias HllConditionalActionsWeb.UserAuth

  plug :require_pending_user
  plug Plugs.TwoFactorRateLimit

  defp require_pending_user(conn, _opts), do: UserAuth.require_pending_user(conn, [])

  def new(conn, _params) do
    render_form(conn, nil)
  end

  def create(conn, %{"code" => code}) do
    user = conn.assigns.pending_user

    case TwoFactor.verify(user, code) do
      {:ok, user} ->
        sign_in(conn, user, greeting(user))

      {:ok, user, :recovery_code_used} ->
        left = TwoFactor.recovery_codes_left(user)

        # Said instead of the greeting, not as well as it: only one info flash
        # survives, and "you are running out of recovery codes" is the half
        # worth keeping.
        sign_in(
          conn,
          user,
          ngettext(
            "Signed in with a recovery code. %{count} left — make new ones from your account page.",
            "Signed in with a recovery code. %{count} left — make new ones from your account page.",
            left,
            count: left
          )
        )

      {:error, :invalid_code} ->
        Plugs.TwoFactorRateLimit.failed(conn, user)

        conn
        |> put_status(:unauthorized)
        |> render_form(gettext("That code is not right. Check your app and try again."))
    end
  end

  def create(conn, _params), do: render_form(conn, nil)

  @doc """
  Abandons a half finished sign in, for somebody who cannot produce a code.
  """
  def delete(conn, _params) do
    conn
    |> put_flash(:info, gettext("You have been signed out."))
    |> UserAuth.log_out_user()
  end

  defp sign_in(conn, user, notice) do
    Plugs.TwoFactorRateLimit.succeeded(conn, user)

    conn
    |> put_flash(:info, notice)
    |> UserAuth.log_in_user(user)
  end

  defp greeting(user) do
    gettext("Welcome back, %{name}!", name: user.name || user.username)
  end

  defp render_form(conn, error) do
    conn
    # The same reasoning as the password form: a cached copy carries a CSRF
    # token for a session that may be gone.
    |> put_resp_header("cache-control", "no-store")
    |> render(:new,
      error: error,
      recovery_codes_left: TwoFactor.recovery_codes_left(conn.assigns.pending_user)
    )
  end
end
