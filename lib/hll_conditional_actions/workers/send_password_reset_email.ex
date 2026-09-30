defmodule HllConditionalActions.Workers.SendPasswordResetEmail do
  @moduledoc """
  Sends an admin account its password reset link
  (`HllConditionalActions.Accounts.PasswordReset`).

  Queued rather than sent during the request, so asking for a link takes
  the same time whether or not the address has an account, and a slow mail
  server never holds up the page. Goes through the mail server configured
  for the VIP shop, the only one the app has.
  """

  use Oban.Worker, queue: :shop, max_attempts: 3

  use Gettext, backend: HllConditionalActionsWeb.Gettext

  import Swoosh.Email

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Accounts.PasswordReset
  alias HllConditionalActions.VipShop
  alias HllConditionalActions.VipShop.Settings
  alias HllConditionalActions.Workers.SendShopEmail

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "url" => url} = args}) do
    settings = VipShop.settings()

    case Accounts.get_user(user_id) do
      %{active: true, email: email} = user when is_binary(email) and email != "" ->
        if Settings.email_configured?(settings) do
          settings |> build(user, url, args["locale"]) |> SendShopEmail.deliver(settings)
        else
          {:cancel, "no mail server configured"}
        end

      _gone ->
        {:cancel, "no such active account"}
    end
  end

  @doc "The message, written in `locale`."
  @spec build(Settings.t(), Accounts.User.t(), String.t(), String.t() | nil) :: Swoosh.Email.t()
  def build(%Settings{} = settings, user, url, locale) do
    Gettext.with_locale(HllConditionalActionsWeb.Gettext, locale || "en", fn ->
      new()
      |> from(
        {settings.mail_from_name || gettext("Conditional Actions"), settings.mail_from_address}
      )
      |> to(user.email)
      |> subject(gettext("Your link to choose a new password"))
      |> text_body(body(user, url))
    end)
  end

  # One msgid per paragraph, so each stays a single line to translate.
  defp body(user, url) do
    Enum.join(
      [
        gettext("Hi %{name},", name: user.name || user.username),
        gettext(
          "Somebody asked for a new password for the account %{username}. To choose one, open this link within %{minutes} minutes:",
          username: user.username,
          minutes: PasswordReset.max_age_minutes()
        ),
        url,
        gettext("If it was not you, ignore this e-mail: your password stays the same.")
      ],
      "\n\n"
    ) <> "\n"
  end
end
