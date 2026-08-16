defmodule HllConditionalActions.Crcon.EventsTest do
  use ExUnit.Case, async: true

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Crcon.Events

  doctest HllConditionalActions.Crcon.Events

  describe "from_log/2" do
    test "normalizes a kill line" do
      event = Events.from_log(log_line())

      assert event.type == :player_kill
      assert event.player_name == "Chris"
      assert event.target_player_name == "Muctar"
      assert event.weapon == "M1 GARAND"
      assert event.occurred_at == ~U[2023-11-14 22:13:20.000Z]
    end

    test "splits the team and scope out of a chat action" do
      event =
        Events.from_log(
          log_line(%{
            "action" => "CHAT[Allies][Unit]",
            "sub_content" => "need ammo",
            "weapon" => nil,
            "player_id_2" => nil,
            "player_name_2" => nil
          })
        )

      assert event.type == :player_chat
      assert event.chat_message == "need ammo"
      assert event.chat_team == "allies"
      assert event.chat_scope == "unit"
    end

    test "an all-chat line has a team but no scope" do
      event = Events.from_log(log_line(%{"action" => "CHAT[Axis]", "sub_content" => "gg"}))

      assert event.chat_team == "axis"
      assert event.chat_scope == nil
    end

    test "blank strings become nil so conditions do not compare against empty text" do
      event = Events.from_log(log_line(%{"player_id_2" => "", "weapon" => ""}))

      assert event.target_player_id == nil
      assert event.weapon == nil
    end

    test "stamps the event with its origin when a server is given" do
      server = %{id: 7, game: :hllv}
      event = Events.from_log(log_line(), server)

      assert event.server_id == 7
      assert event.game == :hllv
    end

    test "falls back to now when the log carries no timestamp" do
      before = DateTime.utc_now()
      event = Events.from_log(%{"action" => "KILL"})

      assert DateTime.compare(event.occurred_at, before) in [:gt, :eq]
    end
  end

  describe "triggers/1" do
    test "a kill fires both a kill and a death trigger" do
      event = Events.from_log(log_line())

      assert Events.triggers(event) == [
               {:player_kill, "76561190000000001", "Chris"},
               {:player_death, "76561190000000002", "Muctar"}
             ]
    end

    test "a kill without a victim id only fires the kill trigger" do
      event = Events.from_log(log_line(%{"player_id_2" => nil}))

      assert Events.triggers(event) == [{:player_kill, "76561190000000001", "Chris"}]
    end

    test "a team kill does not produce a death trigger" do
      event = Events.from_log(log_line(%{"action" => "TEAM KILL"}))

      assert Events.triggers(event) == [{:player_team_kill, "76561190000000001", "Chris"}]
    end

    test "match events have no per-player triggers but are still actionable" do
      event = Events.from_log(log_line(%{"action" => "MATCH ENDED"}))

      assert Events.triggers(event) == []
      assert Events.actionable?(event)
    end

    test "unknown actions are not actionable" do
      event = Events.from_log(log_line(%{"action" => "SOMETHING NEW"}))

      assert event.type == :unknown
      refute Events.actionable?(event)
    end
  end
end
