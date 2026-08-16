defmodule HllConditionalActionsWeb.SessionController do
  @moduledoc """
  Signing in and out.

  Kept as a plain controller rather than a LiveView because writing the session
  cookie needs a real HTTP response.
  """

  use HllConditionalActionsWeb, :controller

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Accounts.TwoFactor
  alias HllConditionalActionsWeb.Plugs
  alias HllConditionalActionsWeb.UserAuth

  def new(conn, params) do
    conn
    # A sign in form restored from the browser cache carries the CSRF token of
    # a session that may already be gone, and submitting it fails. Never
    # caching the form means the back button always lands on a usable one.
    |> put_resp_header("cache-control", "no-store")
    |> render(:new,
      error: expired_error(params),
      username: "",
      first_run?: first_run?()
    )
  end

  def create(conn, %{"user" => %{"username" => username, "password" => password}}) do
    case Accounts.authenticate(username, password) do
      {:ok, user} ->
        # Four typos followed by the right password should leave no trace: the
        # counters only exist to slow guessing down.
        Plugs.LoginRateLimit.succeeded(conn, username)

        if TwoFactor.enabled?(user) do
          UserAuth.start_two_factor(conn, user)
        else
          conn
          |> put_flash(:info, gettext("Welcome back, %{name}!", name: user.name || user.username))
          |> UserAuth.log_in_user(user)
        end

      {:error, :invalid_credentials} ->
        # Deliberately vague: telling somebody the username exists is a gift to
        # whoever is guessing.
        conn
        |> put_status(:unauthorized)
        |> render(:new,
          error: gettext("Wrong username or password."),
          username: username,
          first_run?: first_run?()
        )
    end
  end

  # `HllConditionalActionsWeb.Endpoint` sends visitors here when their form was
  # too old to be accepted, rather than showing them a CSRF error page.
  defp expired_error(%{"expired" => _}),
    do: gettext("Your sign in form had been open too long. Please try again.")

  defp expired_error(_params), do: nil

  def delete(conn, _params) do
    conn
    |> put_flash(:info, gettext("You have been signed out."))
    |> UserAuth.log_out_user()
  end

  # Shows the default credentials hint only while the bootstrap account still
  # has its default password.
  defp first_run? do
    %{username: username} = Accounts.bootstrap_credentials()

    case Accounts.get_user_by_username(username) do
      nil -> false
      user -> user.must_change_password?
    end
  end
end
