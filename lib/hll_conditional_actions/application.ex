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
        {DNSCluster,
         query: Application.get_env(:hll_conditional_actions, :dns_cluster_query) || :ignore},
        {Oban, Application.fetch_env!(:hll_conditional_actions, Oban)},
        {Phoenix.PubSub, name: HllConditionalActions.PubSub},
        # Aggregates our telemetry events so the metrics page has something to
        # show without an external reporter.
        HllConditionalActions.Metrics
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
