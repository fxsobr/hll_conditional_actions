defmodule HllConditionalActionsWeb.TwoFactorHTML do
  @moduledoc """
  Templates for `HllConditionalActionsWeb.TwoFactorController`.

  `new/1` fills in what the code step's throttle
  (`HllConditionalActionsWeb.Plugs.TwoFactorRateLimit`) leaves out when it
  renders the page itself.
  """

  use HllConditionalActionsWeb, :html

  alias HllConditionalActions.Accounts.Totp
  alias HllConditionalActionsWeb.AuthLayout

  embed_templates "two_factor_html/*"

  @doc "The code prompt, with the six digit boxes or the recovery code field."
  def new(assigns) do
    assigns
    |> Map.put_new(:error, nil)
    |> Map.put_new(:recovery?, false)
    |> Map.put_new(:recovery_codes_left, 0)
    |> Map.put_new_lazy(:seconds, &Totp.seconds_remaining/0)
    |> code_form()
  end
end
