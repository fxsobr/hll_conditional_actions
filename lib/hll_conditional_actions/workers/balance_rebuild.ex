defmodule HllConditionalActions.Workers.BalanceRebuild do
  @moduledoc """
  Learns the team balance again from scratch, from the latest matches CRCON
  keeps for every enabled server with the module installed
  (`HllConditionalActions.Balance.rebuild/2`). Started from the Balance
  page; a few minutes of CRCON reads, so it runs in the background, one at
  a time.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: [period: 3600, states: :incomplete]

  require Logger

  alias HllConditionalActions.Balance
  alias HllConditionalActions.Features
  alias HllConditionalActions.Servers

  @matches 500

  @doc "Queues a rebuild. A second one while the first runs is dropped."
  @spec enqueue() :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue, do: %{} |> new() |> Oban.insert()

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    servers = Enum.filter(Servers.list_enabled_servers(), &Features.installed?(&1.id, :balance))
    result = Balance.rebuild(servers, @matches)

    Logger.info(
      "[balance] rebuilt: #{result.imported} matches read from CRCON, #{result.learned} learned"
    )

    Phoenix.PubSub.broadcast(HllConditionalActions.PubSub, "balance", {:balance_rebuilt, result})
    :ok
  end
end
