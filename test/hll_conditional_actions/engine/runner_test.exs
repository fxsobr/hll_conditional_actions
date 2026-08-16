defmodule HllConditionalActions.Engine.RunnerTest do
  @moduledoc """
  The runner's event handling, with the connect race as the case that matters.
  """

  use HllConditionalActions.DataCase, async: false

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Crcon.Events
  alias HllConditionalActions.Crcon.LogStream
  alias HllConditionalActions.Engine.Runner
  alias HllConditionalActions.Rules

  @moduletag :capture_log

  # Long enough to observe the deferral, short enough not to slow the suite.
  @connect_delay_ms 150
  @admitted_after_ms 80

  setup do
    test_pid = self()

    # A CRCON that only knows about the connecting player once the game server
    # has had a moment to admit them - the behaviour that makes an immediate
    # evaluation useless. Anything fetched before `@admitted_after_ms` sees an
    # empty server.
    started = System.monotonic_time(:millisecond)

    Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
      case conn.request_path do
        "/api/get_detailed_players" ->
          elapsed = System.monotonic_time(:millisecond) - started
          send(test_pid, {:players_fetched, elapsed})

          players =
            if elapsed >= @admitted_after_ms do
              %{"76561190000000001" => player(%{"clan_tag" => "CAV", "level" => 12})}
            else
              %{}
            end

          envelope(conn, %{"players" => players, "fail_count" => 0})

        "/api/get_gamestate" ->
          envelope(conn, gamestate())

        path ->
          send(test_pid, {:crcon_called, path})
          envelope(conn, true)
      end
    end)

    server = server_fixture()

    # Keep the wait short so the suite does not sit around for five seconds.
    previous = Application.get_env(:hll_conditional_actions, :connect_delay_ms)
    Application.put_env(:hll_conditional_actions, :connect_delay_ms, @connect_delay_ms)

    on_exit(fn ->
      if previous do
        Application.put_env(:hll_conditional_actions, :connect_delay_ms, previous)
      else
        Application.delete_env(:hll_conditional_actions, :connect_delay_ms)
      end
    end)

    %{server: server}
  end

  defp envelope(conn, result) do
    Req.Test.json(conn, %{"result" => result, "failed" => false, "error" => nil})
  end

  defp connect_event(server) do
    Events.from_log(
      log_line(%{
        "action" => "CONNECTED",
        "player_name_1" => "Chris",
        "player_id_1" => "76561190000000001",
        "player_name_2" => nil,
        "player_id_2" => nil,
        "weapon" => nil
      }),
      server
    )
  end

  defp start_runner(server) do
    # Registered through the runtime registry, which is what `Runner.info/1`
    # looks the process up in.
    pid = start_supervised!({Runner, server: server})
    # The sandbox connection belongs to the test process; hand it to the runner.
    Ecto.Adapters.SQL.Sandbox.allow(HllConditionalActions.Repo, self(), pid)
    pid
  end

  describe "a connect" do
    test "is acted on only after the player exists in CRCON's view", %{server: server} do
      # A welcome rule that reads a field only the snapshot can answer, which is
      # exactly the shape that used to fire for some players and not others.
      _rule =
        rule_fixture(%{
          trigger_event: :player_connected,
          conditions: [%{field: :clan_tag, operator: :equal, value: "CAV"}],
          actions: [%{type: :message_player, parameters: %{"message" => "Hi {player_name}"}}]
        })

      pid = start_runner(server)
      send(pid, {:crcon_event, connect_event(server)})

      # Nothing may happen while the game server is still admitting them:
      # evaluating now would read a clan tag that does not exist yet.
      refute_receive {:players_fetched, _}, @admitted_after_ms

      assert_receive {:players_fetched, elapsed}, 2_000
      assert elapsed >= @admitted_after_ms

      assert_receive {:crcon_called, "/api/message_player"}, 2_000

      # The message goes out from inside the runner's own call, before it
      # writes the results back; wait for it to finish that turn.
      _ = :sys.get_state(pid)

      assert [execution] = Rules.list_executions()
      assert execution.player_name == "Chris"
      assert [%{"detail" => "Hi Chris"}] = execution.results
    end

    test "is ignored entirely when no rule listens for it", %{server: server} do
      _rule = rule_fixture(%{trigger_event: :player_kill})

      pid = start_runner(server)
      send(pid, {:crcon_event, connect_event(server)})
      _ = :sys.get_state(pid)

      refute_receive {:players_fetched, _}, 300
      assert Rules.list_executions() == []
    end
  end

  describe "other events" do
    test "are acted on immediately", %{server: server} do
      _rule =
        rule_fixture(%{
          trigger_event: :player_kill,
          conditions: [%{field: :always_true, operator: :equal, value: ""}],
          actions: [%{type: :punish_player, parameters: %{"reason" => "no"}}]
        })

      pid = start_runner(server)
      send(pid, {:crcon_event, Events.from_log(log_line(), server)})

      assert_receive {:crcon_called, "/api/punish"}, 2_000
    end

    test "cost nothing when no rule listens", %{server: server} do
      pid = start_runner(server)
      send(pid, {:crcon_event, Events.from_log(log_line(), server)})
      _ = :sys.get_state(pid)

      refute_receive {:players_fetched, _}, 300
    end
  end

  test "the runner reports how many rules it holds", %{server: server} do
    _rule = rule_fixture()
    start_runner(server)

    assert %{rules: 1} = Runner.info(server.id)
  end

  test "an unknown server reports itself offline" do
    assert Runner.info(-1) == :offline
  end

  test "the log stream topic is the one the runner subscribes to", %{server: server} do
    assert LogStream.topic(server.id) =~ to_string(server.id)
  end
end
