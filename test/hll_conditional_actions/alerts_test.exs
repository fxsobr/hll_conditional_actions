defmodule HllConditionalActions.AlertsTest do
  use HllConditionalActions.DataCase, async: false

  import HllConditionalActions.Fixtures
  import Req.Test, only: [set_req_test_to_shared: 1]

  alias HllConditionalActions.Alerts

  # Messages are posted from a task, which the stub must reach.
  setup :set_req_test_to_shared

  setup do
    test = self()

    Req.Test.stub(HllConditionalActions.Discord, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:posted, Jason.decode!(body)["content"]})
      Req.Test.json(conn, %{"id" => "1"})
    end)

    pid =
      start_supervised!(
        {Alerts,
         url: "https://discord.test/api/webhooks/1/token",
         check_ms: nil,
         stream_grace_ms: 0,
         digest_every_ms: 0}
      )

    %{alerts: pid, server: server_fixture(%{name: "EU #1"})}
  end

  test "a stream that stays down is reported once, and so is its return", %{
    alerts: pid,
    server: server
  } do
    send(pid, {:crcon_stream_status, server.id, {:error, "socket closed"}})
    :ok = Alerts.check(pid)

    assert_receive {:posted, text}, 2_000
    assert text =~ "EU #1"
    assert text =~ "socket closed"

    :ok = Alerts.check(pid)
    refute_receive {:posted, _again}, 200

    send(pid, {:crcon_stream_status, server.id, :connected})
    assert_receive {:posted, back}, 2_000
    assert back =~ "EU #1"
  end

  test "a stream that comes back before the alert says nothing", %{alerts: pid, server: server} do
    send(pid, {:crcon_stream_status, server.id, {:error, "socket closed"}})
    send(pid, {:crcon_stream_status, server.id, :connected})
    :ok = Alerts.check(pid)

    refute_receive {:posted, _text}, 200
  end

  test "errors and slow pages are gathered into one message", %{alerts: pid} do
    send(pid, {:problem, :error, "/rules", nil})
    send(pid, {:problem, :slow, "/", 15_000})
    :ok = Alerts.check(pid)

    assert_receive {:posted, text}, 2_000
    assert text =~ "/rules"
    assert text =~ "15"
  end
end
