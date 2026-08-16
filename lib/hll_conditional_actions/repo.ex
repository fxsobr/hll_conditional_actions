defmodule HllConditionalActions.Repo do
  use Ecto.Repo,
    otp_app: :hll_conditional_actions,
    adapter: Ecto.Adapters.Postgres
end
