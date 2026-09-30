defmodule HllConditionalActions.Workers.PruneSavedEvents do
  @moduledoc """
  Deletes saved events older than `HllConditionalActions.Engine.SavedEvents.retention_days/0`.

  Runs hourly from the Oban cron. The per trigger cap is kept on write by
  `HllConditionalActions.Engine.Samples`; this is the age half of the
  retention, so a quiet trigger's events leave after a week even when
  nothing new pushes them out.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger

  alias HllConditionalActions.Engine.SavedEvents

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    deleted = SavedEvents.prune_old()

    if deleted > 0 do
      Logger.info(
        "[workers] pruned #{deleted} saved events older than #{SavedEvents.retention_days()} days"
      )
    end

    :ok
  end
end
