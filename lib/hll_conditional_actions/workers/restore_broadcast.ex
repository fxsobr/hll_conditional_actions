defmodule HllConditionalActions.Workers.RestoreBroadcast do
  @moduledoc """
  Puts a server's previous broadcast message back after a temporary one expires.

  CRCON has no "broadcast for N seconds" command, so the `temporary_broadcast`
  action sets the new message immediately and schedules this job to restore the
  old one. Going through Oban rather than a sleeping process means the restore
  survives a deploy or a crash in between.
  """

  use Oban.Worker, queue: :actions, max_attempts: 5

  require Logger

  alias HllConditionalActions.Crcon
  alias HllConditionalActions.Servers

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"server_id" => server_id, "message" => message}}) do
    case Servers.fetch_server(server_id) do
      {:ok, server} ->
        restore(server, message)

      :error ->
        # The server was deleted while the job was waiting; nothing to restore.
        Logger.info("[workers] skipping broadcast restore, server #{server_id} is gone")
        :ok
    end
  end

  @doc """
  Schedules the restore of `message` on a server in `seconds`.
  """
  @spec schedule(term(), String.t(), pos_integer()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def schedule(server_id, message, seconds) do
    %{server_id: server_id, message: message}
    |> new(schedule_in: seconds)
    |> Oban.insert()
  end

  defp restore(server, message) do
    case Crcon.set_broadcast(server, message) do
      {:ok, _result} ->
        :ok

      {:error, error} ->
        {:error, "could not restore broadcast on #{server.name}: #{Exception.message(error)}"}
    end
  end
end
