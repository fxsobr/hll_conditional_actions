defmodule HllConditionalActions.Rules.TransferTest do
  use HllConditionalActions.DataCase, async: true

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Transfer

  doctest HllConditionalActions.Rules.Transfer

  describe "export" do
    test "round trips a rule through JSON" do
      server = server_fixture()

      _rule =
        rule_fixture(%{
          name: "Welcome newcomers",
          game: :hll,
          server_id: server.id,
          trigger_event: :player_connected,
          conditions: [%{field: :player_level, operator: :less_than, value: "10"}],
          actions: [%{type: :message_player, parameters: %{"message" => "Hi {player_name}"}}]
        })

      json = Rules.export_rules(Rules.list_rules())

      # Wipe the source so the import is proven to rebuild from the file alone.
      Enum.each(Rules.list_rules(), &Rules.delete_rule/1)
      assert Rules.list_rules() == []

      assert {:ok, [imported]} = Rules.import_rules(json)

      assert imported.name == "Welcome newcomers"
      assert imported.game == :hll
      assert imported.trigger_event == :player_connected
      assert [%{field: :player_level, operator: :less_than, value: "10"}] = imported.conditions

      assert [%{type: :message_player, parameters: %{"message" => "Hi {player_name}"}}] =
               imported.actions
    end

    test "does not carry the server, whose id means nothing elsewhere" do
      server = server_fixture()
      _rule = rule_fixture(%{server_id: server.id})

      json = Rules.export_rules(Rules.list_rules())

      refute json =~ "server_id"
      assert {:ok, [attrs]} = Rules.preview_import(json)
      assert attrs["server_id"] == nil
    end

    test "carries the game, since a Vietnam rule is not valid for WW2" do
      _rule = rule_fixture(%{game: :hllv})

      assert Rules.export_rules(Rules.list_rules()) =~ ~s("game": "hllv")
    end

    test "the export is stamped with its format and version" do
      payload = Transfer.export([])

      assert payload["format"] == Transfer.format()
      assert payload["version"] == Transfer.version()
      assert payload["exported_at"]
    end
  end

  describe "import" do
    test "pins the imported rules to a server when asked" do
      server = server_fixture()
      _rule = rule_fixture(%{game: :hll, server_id: nil})
      json = Rules.export_rules(Rules.list_rules())
      Enum.each(Rules.list_rules(), &Rules.delete_rule/1)

      assert {:ok, [imported]} = Rules.import_rules(json, server_id: server.id)
      assert imported.server_id == server.id
    end

    test "arriving disabled is the safe default the UI asks for" do
      _rule = rule_fixture(%{enabled: true})
      json = Rules.export_rules(Rules.list_rules())
      Enum.each(Rules.list_rules(), &Rules.delete_rule/1)

      assert {:ok, [imported]} = Rules.import_rules(json, enabled: false)
      refute imported.enabled
    end

    test "one invalid rule imports nothing at all" do
      json =
        Jason.encode!(%{
          "format" => Transfer.format(),
          "version" => 1,
          "rules" => [
            %{
              "name" => "Fine",
              "game" => "hll",
              "trigger_event" => "player_connected",
              "logical_operator" => "and",
              "conditions" => [%{"field" => "always_true", "operator" => "equal", "value" => ""}],
              "actions" => [%{"type" => "message_player", "parameters" => %{"message" => "hi"}}]
            },
            %{"name" => "Broken", "game" => "hll", "trigger_event" => "player_connected"}
          ]
        })

      assert {:error, 1, changeset} = Rules.import_rules(json)
      assert errors_on(changeset)[:conditions]
      assert Rules.list_rules() == [], "the valid rule must have been rolled back"
    end

    test "rejects a file from a newer format version" do
      json = Jason.encode!(%{"format" => Transfer.format(), "version" => 99, "rules" => []})

      assert {:error, message} = Rules.import_rules(json)
      assert message =~ "newer version"
    end

    test "rejects something that is not JSON" do
      assert {:error, message} = Rules.import_rules("not json at all")
      assert message =~ "not valid JSON"
    end

    test "rejects an export of something else" do
      json = Jason.encode!(%{"format" => "some.other.tool", "rules" => []})

      assert {:error, message} = Rules.import_rules(json)
      assert message =~ "unknown export format"
    end

    test "a hand-written file without a format marker is accepted" do
      json =
        Jason.encode!(%{
          "rules" => [
            %{
              "name" => "Hand written",
              "game" => "hll",
              "trigger_event" => "player_connected",
              "logical_operator" => "and",
              "conditions" => [%{"field" => "always_true", "operator" => "equal", "value" => ""}],
              "actions" => [%{"type" => "message_player", "parameters" => %{"message" => "hi"}}]
            }
          ]
        })

      assert {:ok, [rule]} = Rules.import_rules(json)
      assert rule.name == "Hand written"
    end
  end
end
