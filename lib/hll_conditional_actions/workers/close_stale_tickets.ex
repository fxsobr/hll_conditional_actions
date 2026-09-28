defmodule HllConditionalActions.Workers.CloseStaleTickets do
  @moduledoc """
  Closes tickets nobody touched for longer than their server's
  `auto_close_hours`. See `HllConditionalActions.Tickets.close_stale/0`.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger

  alias HllConditionalActions.Tickets

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    closed = Tickets.close_stale()

    if closed > 0, do: Logger.info("[workers] closed #{closed} inactive tickets")

    :ok
  end
end
