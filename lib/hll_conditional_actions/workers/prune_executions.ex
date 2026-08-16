defmodule HllConditionalActions.Workers.PruneExecutions do
  @moduledoc """
  Deletes rule execution history older than the configured retention.

  A busy fleet writes a row every time any rule fires, so without pruning the
  audit table grows without bound. Retention is set with
  `EXECUTION_RETENTION_DAYS` and defaults to 30 days.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger

  alias HllConditionalActions.Rules

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    days = Application.get_env(:hll_conditional_actions, :execution_retention_days, 30)
    {deleted, _} = Rules.prune_executions(days)

    if deleted > 0 do
      Logger.info("[workers] pruned #{deleted} rule executions older than #{days} days")
    end

    :ok
  end
end
