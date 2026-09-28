defmodule HllConditionalActions.Application do
  @moduledoc false

  use Application

  alias HllConditionalActions.Runtime

  @impl true
  def start(_type, _args) do
    children =
      [
        HllConditionalActionsWeb.Telemetry,
        # Owns the sign in attempt counters. Before the endpoint, so the very
        # first request already has something counting it.
        HllConditionalActions.RateLimit,
        # The vault must be up before the repo, since loading a server decrypts
        # its API key.
        HllConditionalActions.Vault,
        HllConditionalActions.Repo,
        # Seeds the built-in roles and the first administrator on a fresh
        # database, so a new deployment is never locked out.
        HllConditionalActions.Accounts.Bootstrap,
        # Moves webhook URLs that older rules kept in their actions into
        # encrypted, registered webhooks. A no-op once that is done.
        legacy_webhooks(),
        {DNSCluster,
         query: Application.get_env(:hll_conditional_actions, :dns_cluster_query) || :ignore},
        {Oban, Application.fetch_env!(:hll_conditional_actions, Oban)},
        {Phoenix.PubSub, name: HllConditionalActions.PubSub},
        # Who has a ticket open, so admins do not answer the same player twice.
        HllConditionalActionsWeb.Presence,
        # Aggregates our telemetry events so the metrics page has something to
        # show without an external reporter.
        HllConditionalActions.Metrics,
        # The last evaluations per server and trigger, which the rule builder
        # replays an edited rule against.
        HllConditionalActions.Engine.Samples
      ] ++
        update_checker() ++
        Runtime.children() ++
        [
          # Serve requests last, so the engine is ready before traffic arrives.
          HllConditionalActionsWeb.Endpoint
        ]

    opts = [strategy: :one_for_one, name: HllConditionalActions.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp legacy_webhooks do
    if Application.get_env(:hll_conditional_actions, :adopt_legacy_webhooks, true),
      do: {Task, &HllConditionalActions.Discord.adopt_legacy_urls/0},
      else: {Task, fn -> :ok end}
  end

  # Asks GitHub about newer releases on a timer. Off in test, where nothing
  # may reach the network.
  defp update_checker do
    if Application.get_env(:hll_conditional_actions, :updates_enabled, true) do
      [HllConditionalActions.Updates]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    HllConditionalActionsWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
