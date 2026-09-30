defmodule HllConditionalActionsWeb.SessionHTML do
  @moduledoc """
  Templates for `HllConditionalActionsWeb.SessionController`.

  Everything lives on `/login`, so `new/1` picks the screen from `:mode`:

    * `:login` - username and password
    * `:forgot` - "Esqueci a senha", asking for the e-mail
    * `:sent` - "Confira seu e-mail"
    * `:reset` - choosing the new password from the e-mailed link

  `new/1` also fills in what a caller left out, because the login throttle
  (`HllConditionalActionsWeb.Plugs.LoginRateLimit`) renders it with only an
  error, a username and `first_run?`.
  """

  use HllConditionalActionsWeb, :html

  alias HllConditionalActions.Accounts.PasswordReset
  alias HllConditionalActionsWeb.AuthLayout

  embed_templates "session_html/*"

  @defaults %{
    mode: :login,
    error: nil,
    username: "",
    first_run?: false,
    email: "",
    mail_configured?: true,
    resend_seconds: 60,
    token: nil,
    reset_username: nil,
    errors: []
  }

  @doc "The page at `/login`, in the mode the controller asked for."
  def new(assigns) do
    assigns = Map.merge(@defaults, assigns)

    case assigns.mode do
      :forgot -> forgot(assigns)
      :sent -> reset_sent(assigns)
      :reset -> reset_form(assigns)
      _login -> login(assigns)
    end
  end

  defp masked(email), do: PasswordReset.mask(email)
end
