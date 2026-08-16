defmodule HllConditionalActions.Vault do
  @moduledoc """
  Cloak vault used to encrypt CRCON API keys at rest.

  An API key grants full admin control over a game server, so it must not sit
  in the database in clear text where a backup or a stray `SELECT` would expose
  it. The key material comes from the `ENCRYPTION_KEY` environment variable and
  is wired up in `config/runtime.exs`.

  Generate one with:

      mix phx.gen.secret 32 | head -c 32 | base64
  """

  use Cloak.Vault, otp_app: :hll_conditional_actions
end
