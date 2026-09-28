defmodule HllConditionalActions.Workers.FinalizeSeasons do
  @moduledoc """
  Closes the seasons whose time is up, every few minutes: ranks them,
  rewards the winners and starts the next one. See
  `HllConditionalActions.Progression.finalize_due_seasons/1`. It also lets
  the ratings of idle players decay (`Progression.decay_ratings/1`).
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger

  alias HllConditionalActions.Progression

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    for season <- Progression.finalize_due_seasons() do
      Logger.info("[seasons] closed #{season.name}")
    end

    case Progression.decay_ratings() do
      0 -> :ok
      count -> Logger.info("[seasons] #{count} idle ratings decayed")
    end

    :ok
  end
end
