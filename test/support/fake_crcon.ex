defmodule HllConditionalActions.FakeCrcon do
  @moduledoc """
  A stand-in for a CRCON deployment's `/ws/logs` endpoint.

  Real CRCON accepts the WebSocket upgrade first and only then decides whether
  it will actually stream: a deployment with `log_stream.enabled` set to false
  answers the client's first message with an error and disconnects. That
  ordering is the reason `HllConditionalActions.Crcon.LogStream` cannot treat a
  successful handshake as "the stream works", so the fake reproduces it.

  ## Usage

      port = FakeCrcon.free_port()
      start_supervised!(FakeCrcon.child_spec(port: port, mode: :disabled))

  ## Modes

    * `{:logs, entries}` - answers with a batch of log lines
    * `:disabled` - answers with CRCON's "log stream is not enabled" error
    * `:unauthorized` - refuses the upgrade with 403
  """

  alias HllConditionalActions.FakeCrcon.Router

  @doc """
  A Bandit child spec serving the fake on `:port` in the given `:mode`.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    port = Keyword.fetch!(opts, :port)
    mode = Keyword.fetch!(opts, :mode)

    Supervisor.child_spec(
      {Bandit, plug: {Router, mode}, port: port, ip: {127, 0, 0, 1}, startup_log: false},
      id: {__MODULE__, port}
    )
  end

  @doc """
  A port nothing else is listening on.

  Binding to port 0 lets the OS pick a free one; closing the socket right away
  leaves a small race, which is fine for a test and avoids a fixed port that
  would clash between runs.
  """
  @spec free_port() :: pos_integer()
  def free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
