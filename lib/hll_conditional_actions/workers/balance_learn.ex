defmodule HllConditionalActions.Workers.BalanceLearn do
  @moduledoc """
  Keeps the team balance learning, every few minutes: for each enabled
  server with the module installed, reads the matches CRCON finished since
  the last time (`Players.MatchHistory.sync/2`) and learns from them
  (`HllConditionalActions.Balance.learn_pending/1`). Once an hour it also
  forgets partnerships that happened once, a month ago.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1

  require Logger

  alias HllConditionalActions.Balance
  alias HllConditionalActions.Features
  alias HllConditionalActions.Players.MatchHistory
  alias HllConditionalActions.Servers

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    servers = Enum.filter(Servers.list_enabled_servers(), &Features.installed?(&1.id, :balance))

    for server <- servers do
      MatchHistory.sync(server)

      case Balance.learn_pending(server) do
        0 -> :ok
        count -> Logger.info("[balance] #{server.name}: learned from #{count} matches")
      end
    end

    if servers != [] and DateTime.utc_now().minute < 5, do: Balance.prune_partners()

    :ok
  end
end
