defmodule HllConditionalActions.Mailer do
  @moduledoc """
  Sends email. The SMTP server is configured by an admin in the VIP shop, so
  production passes it on each delivery (`deliver(email, config)`); tests use
  Swoosh's test adapter from `config/test.exs`.
  """

  use Swoosh.Mailer, otp_app: :hll_conditional_actions
end
