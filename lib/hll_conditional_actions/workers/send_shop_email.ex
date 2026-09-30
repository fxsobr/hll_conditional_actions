defmodule HllConditionalActions.Workers.SendShopEmail do
  @moduledoc """
  Sends one of the shop's emails. Queued, so a slow or unreachable mail
  server never holds up a sign up or a purchase, and retried a few times.
  Skipped when no mail server is configured.
  """

  use Oban.Worker, queue: :shop, max_attempts: 4

  alias HllConditionalActions.Mailer
  alias HllConditionalActions.VipShop
  alias HllConditionalActions.VipShop.{Emails, Settings}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"to" => to, "template" => template, "vars" => vars}}) do
    settings = VipShop.settings()

    if Settings.email_configured?(settings) do
      started = System.monotonic_time(:millisecond)
      result = settings |> Emails.build(template, to, vars) |> deliver(settings)

      # The email page counts what went out and what the service refused.
      HllConditionalActions.VipShop.Stats.log_email(
        template,
        to,
        result,
        System.monotonic_time(:millisecond) - started
      )

      result
    else
      {:cancel, "no mail server configured"}
    end
  end

  @doc "Delivers a built email through the configured server."
  @spec deliver(Swoosh.Email.t(), Settings.t()) :: :ok | {:error, term()}
  def deliver(email, settings) do
    config =
      if Application.get_env(:hll_conditional_actions, Mailer)[:adapter] == Swoosh.Adapters.Test,
        do: [],
        else: Emails.delivery_config(settings)

    case Mailer.deliver(email, config) do
      {:ok, _meta} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
