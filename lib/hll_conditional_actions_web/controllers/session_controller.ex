defmodule HllConditionalActionsWeb.SessionController do
  @moduledoc """
  Signing in and out, and "Esqueci a senha".

  Kept as a plain controller rather than a LiveView because writing the session
  cookie needs a real HTTP response.

  The forgotten password flow lives on `/login` too, so it sits behind the
  same throttle as the password form:

    * `GET /login?forgot=1` asks for the e-mail
    * `POST /login` with `reset[email]` sends the link and says "check your
      e-mail" - the same whether or not the address has an account
    * `GET /login?reset_token=...` (the link) asks for the new password
    * `POST /login` with `reset_password[...]` saves it and goes back to the
      sign in form

  See `HllConditionalActions.Accounts.PasswordReset`.
  """

  use HllConditionalActionsWeb, :controller

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Accounts.PasswordReset
  alias HllConditionalActions.Accounts.TwoFactor
  alias HllConditionalActionsWeb.CoreComponents
  alias HllConditionalActionsWeb.Plugs
  alias HllConditionalActionsWeb.UserAuth

  # How long "Reenviar" waits after a link was sent.
  @resend_seconds 60

  def new(conn, %{"reset_token" => token}) do
    case PasswordReset.verify(token) do
      {:ok, user} -> render_page(conn, mode: :reset, token: token, reset_username: user.username)
      :error -> render_page(conn, mode: :forgot, error: dead_link_error())
    end
  end

  def new(conn, %{"forgot" => _}) do
    render_page(conn, mode: :forgot)
  end

  def new(conn, params) do
    render_page(conn, error: expired_error(params), first_run?: first_run?())
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
        |> render_page(
          error: gettext("Wrong username or password."),
          username: username,
          first_run?: first_run?()
        )
    end
  end

  def create(conn, %{"reset" => %{"email" => email}}) do
    locale = Gettext.get_locale(HllConditionalActionsWeb.Gettext)
    link = fn token -> url(~p"/login?#{[reset_token: token]}") end

    case PasswordReset.request(email, link, locale) do
      :ok ->
        render_page(conn,
          mode: :sent,
          email: PasswordReset.normalize(email),
          resend_seconds: @resend_seconds
        )

      :not_configured ->
        render_page(conn, mode: :forgot, mail_configured?: false)
    end
  end

  def create(conn, %{"reset_password" => %{"token" => token} = attrs}) do
    case PasswordReset.reset(token, Map.take(attrs, ["password", "password_confirmation"])) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, gettext("Password changed. Sign in with the new one."))
        |> redirect(to: ~p"/login")

      {:error, :invalid_token} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render_page(mode: :forgot, error: dead_link_error())

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render_page(
          mode: :reset,
          token: token,
          reset_username: changeset.data.username,
          errors: password_errors(changeset)
        )
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, gettext("You have been signed out."))
    |> UserAuth.log_out_user()
  end

  defp render_page(conn, assigns) do
    conn
    # A sign in form restored from the browser cache carries the CSRF token of
    # a session that may already be gone, and submitting it fails. Never
    # caching the form means the back button always lands on a usable one.
    |> put_resp_header("cache-control", "no-store")
    # A reset link in the address bar must not leak to anything the page loads.
    |> put_resp_header("referrer-policy", "no-referrer")
    |> render(:new, Keyword.put(assigns, :mail_configured?, mail_configured?(assigns)))
  end

  # Only the forgotten-password screens need to know, and asking costs a query.
  defp mail_configured?(assigns) do
    case Keyword.fetch(assigns, :mail_configured?) do
      {:ok, value} -> value
      :error -> Keyword.get(assigns, :mode) == :forgot and PasswordReset.mail_configured?()
    end
  end

  # `HllConditionalActionsWeb.Endpoint` sends visitors here when their form was
  # too old to be accepted, rather than showing them a CSRF error page.
  defp expired_error(%{"expired" => _}),
    do: gettext("Your sign in form had been open too long. Please try again.")

  defp expired_error(_params), do: nil

  defp dead_link_error,
    do: gettext("This link has expired or was already used. Ask for a new one below.")

  defp password_errors(changeset) do
    changeset.errors
    |> Keyword.take([:password, :password_confirmation])
    |> Enum.map(fn {_field, error} -> CoreComponents.translate_error(error) end)
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
