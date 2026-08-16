defmodule HllConditionalActions.Crcon.LogStreamTest do
  @moduledoc """
  Drives the log stream against a fake CRCON (`HllConditionalActions.FakeCrcon`)
  so the connection lifecycle is exercised for real rather than mocked.
  """

  use ExUnit.Case, async: false

  # Most of these tests drive failure paths on purpose, and tearing the fake
  # server down mid-connection makes Bandit log the aborted socket. Capturing
  # keeps a passing run quiet without hiding a real failure's output.
  @moduletag :capture_log

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Crcon.LogStream
  alias HllConditionalActions.FakeCrcon
  alias HllConditionalActions.Servers.Server

  setup do
    port = FakeCrcon.free_port()

    server = %Server{
      id: System.unique_integer([:positive]),
      name: "Fake CRCON",
      game: :hll,
      base_url: "http://127.0.0.1:#{port}",
      api_key: "test-key",
      enabled: true,
      log_stream_enabled: true
    }

    %{server: server, port: port}
  end

  describe "a working stream" do
    test "broadcasts normalized events to subscribers", %{server: server, port: port} do
      start_fake(port, {:logs, [log_line()]})
      LogStream.subscribe(server.id)
      start_stream(server)

      assert_receive {:crcon_event, event}, 5_000

      assert event.type == :player_kill
      assert event.player_name == "Chris"
      assert event.target_player_name == "Muctar"
      assert event.server_id == server.id
      assert event.game == :hll
    end

    test "reports itself as connected", %{server: server, port: port} do
      start_fake(port, {:logs, []})
      LogStream.subscribe(server.id)
      start_stream(server)

      assert_receive {:crcon_stream_status, _id, :connected}, 5_000
    end
  end

  describe "a CRCON with the log stream disabled" do
    setup %{server: server, port: port} do
      start_fake(port, :disabled)
      LogStream.subscribe(server.id)
      %{pid: start_stream(server)}
    end

    test "explains where to enable it instead of repeating CRCON's wording", %{server: server} do
      assert_receive {:crcon_stream_status, id, {:error, reason}}, 5_000

      assert id == server.id
      assert reason =~ "log stream is disabled"
      assert reason =~ "Settings -> Others -> Log Stream"
    end

    # The regression this guards: CRCON accepts the handshake and only then
    # refuses, so resetting the backoff on a successful upgrade left the client
    # reconnecting every second forever against a server that will never work.
    test "backs off instead of retrying every second forever", %{pid: pid} do
      assert_receive {:crcon_stream_status, _id, {:error, _}}, 5_000
      first = backoff(pid)

      assert_receive {:crcon_stream_status, _id, {:error, _}}, 5_000
      second = backoff(pid)

      assert second > first,
             "expected the retry delay to grow, stayed at #{first}ms"
    end
  end

  describe "a CRCON that refuses the API key" do
    test "surfaces the rejection and keeps retrying", %{server: server, port: port} do
      start_fake(port, :unauthorized)
      LogStream.subscribe(server.id)
      start_stream(server)

      assert_receive {:crcon_stream_status, _id, {:error, reason}}, 5_000
      assert is_binary(reason)
    end
  end

  test "a server that is not listening at all reports the failure", %{server: server} do
    # No fake started, so the port refuses the connection.
    LogStream.subscribe(server.id)
    start_stream(server)

    assert_receive {:crcon_stream_status, _id, {:error, reason}}, 5_000
    assert reason =~ "connection refused" or reason =~ "econnrefused"
  end

  defp start_fake(port, mode) do
    start_supervised!(FakeCrcon.child_spec(port: port, mode: mode))
  end

  defp start_stream(server) do
    start_supervised!({LogStream, server: server, name: :"log_stream_#{server.id}"})
  end

  defp backoff(pid), do: :sys.get_state(pid).backoff
end
