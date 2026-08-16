defmodule HllConditionalActions.Runtime.ServerSupervisor do
  @moduledoc """
  Supervises the two processes that serve one CRCON server: its log stream and
  its rule runner.

  Registered under `{:supervisor, server_id}` so
  `HllConditionalActions.Runtime` can find and stop the subtree when the server
  is disabled or deleted.
  """

  use Supervisor

  alias HllConditionalActions.Crcon.LogStream
  alias HllConditionalActions.Engine.Runner
  alias HllConditionalActions.Servers.Server

  @registry HllConditionalActions.Runtime.Registry

  @doc """
  Starts the subtree for a server.
  """
  def start_link(%Server{} = server) do
    Supervisor.start_link(__MODULE__, server, name: via(server.id))
  end

  @doc """
  Returns the registry key of a server's subtree.
  """
  def via(server_id), do: {:via, Registry, {@registry, {:supervisor, server_id}}}

  @impl Supervisor
  def init(%Server{} = server) do
    children =
      [{Runner, server: server}] ++
        if server.log_stream_enabled, do: [{LogStream, server: server}], else: []

    # The runner subscribes to the stream's topic when it starts, so if either
    # dies they both restart and the subscription is guaranteed to exist.
    Supervisor.init(children, strategy: :one_for_all, max_restarts: 5, max_seconds: 60)
  end
end
