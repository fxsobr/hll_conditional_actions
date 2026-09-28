defmodule HllConditionalActions.Rules.ExemptionsAndLimitsTest do
  use HllConditionalActions.DataCase, async: false

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Engine
  alias HllConditionalActions.Engine.Context
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Exemptions
  alias HllConditionalActions.Rules.Rule
  alias HllConditionalActions.Rules.Transfer
  alias HllConditionalActionsWeb.RuleLive.Form

  doctest HllConditionalActions.Rules.Exemptions

  defp attrs(extra) do
    Map.merge(
      %{
        "name" => "A rule",
        "game" => "hll",
        "trigger_event" => "player_connected",
        "logical_operator" => "and",
        "conditions" => [%{"field" => "always_true", "operator" => "equal", "value" => ""}],
        "actions" => [%{"type" => "message_player", "parameters" => %{"message" => "Hi"}}]
      },
      extra
    )
  end

  defp build(extra), do: Rules.change_rule(%Rule{}, attrs(extra))

  describe "exemptions" do
    test "the builder's comma separated lists are split and cleaned" do
      changeset =
        build(%{
          "exemptions" => %{
            "exempt_vip" => "true",
            "exempt_flags" => " staff, ,admin,staff",
            "exempt_player_ids" => "1,2"
          }
        })

      exemptions = Ecto.Changeset.get_field(changeset, :exemptions)
      assert exemptions.exempt_vip
      assert exemptions.exempt_flags == ["staff", "admin"]
      assert exemptions.exempt_player_ids == ["1", "2"]
    end

    test "the engine skips an exempt VIP before evaluating anything" do
      Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
        Req.Test.json(conn, %{"result" => true, "failed" => false, "error" => nil})
      end)

      server = server_fixture()
      rule = rule_fixture(%{exemptions: %{exempt_vip: true}})

      vip = Context.build(server, :player_connected, player: player(%{"is_vip" => true}))
      regular = Context.build(server, :player_connected, player: player())

      assert {:skip, :exempt} = Engine.run_rule(rule, vip)
      assert {:ok, _execution} = Engine.run_rule(rule, regular)
    end

    test "flags are matched from the profile, ignoring case" do
      server = server_fixture()
      rule = %Rule{exemptions: %Exemptions{exempt_flags: ["Staff"]}}

      staff =
        Context.build(server, :player_connected,
          player: player(),
          player_profile: %{"flags" => [%{"flag" => "staff"}]}
        )

      assert Engine.exempt?(rule, staff)
      refute Engine.exempt?(rule, Context.build(server, :player_connected, player: player()))
    end

    test "a rule loaded without exemptions applies to everybody" do
      server = server_fixture()
      context = Context.build(server, :player_connected, player: player(%{"is_vip" => true}))

      refute Engine.exempt?(%Rule{exemptions: nil}, context)
    end

    test "exemptions travel through export and import" do
      rule =
        rule_fixture(%{exemptions: %{exempt_vip: true, exempt_player_ids: ["76561190000000009"]}})

      json = Transfer.encode([rule])
      assert {:ok, [imported]} = Transfer.decode(json)

      assert {:ok, copy} = Rules.create_rule(imported)
      assert copy.exemptions.exempt_vip
      assert copy.exemptions.exempt_player_ids == ["76561190000000009"]
    end

    test "files from before exemptions import with none" do
      payload = %{"rules" => [attrs(%{})]}
      assert {:ok, [imported]} = Transfer.decode(payload)
      assert imported["exemptions"] == %{}
    end
  end

  describe "limits in plain language" do
    test "the cooldown switch and duration become seconds" do
      changeset =
        build(%{
          "cooldown_enabled" => "true",
          "cooldown_value" => "10",
          "cooldown_unit" => "min"
        })

      assert Ecto.Changeset.get_field(changeset, :cooldown_seconds) == 600
    end

    test "switching the cooldown off zeroes it, whatever value is left behind" do
      changeset =
        build(%{
          "cooldown_enabled" => "false",
          "cooldown_value" => "10",
          "cooldown_seconds" => 60
        })

      assert Ecto.Changeset.get_field(changeset, :cooldown_seconds) == 0
    end

    test "a zero cooldown while switched on is an error, not a silent off" do
      changeset = build(%{"cooldown_enabled" => "true", "cooldown_value" => "0"})

      assert %{cooldown_value: [_message]} = errors_on(changeset)
    end

    test "seconds from the API are shown back as value and unit" do
      changeset = build(%{"cooldown_seconds" => 7200})

      assert Ecto.Changeset.get_field(changeset, :cooldown_enabled)
      assert Ecto.Changeset.get_field(changeset, :cooldown_value) == 2
      assert Ecto.Changeset.get_field(changeset, :cooldown_unit) == "h"
    end

    test "turning the daily cap on without a number starts it at 3" do
      changeset = build(%{"cap_enabled" => "true"})
      assert Ecto.Changeset.get_field(changeset, :max_executions_per_player) == 3

      changeset = build(%{"cap_enabled" => "false", "max_executions_per_player" => "5"})
      assert Ecto.Changeset.get_field(changeset, :max_executions_per_player) == 0
    end

    test "the sentence explains the combined effect" do
      rule = %Rule{
        cooldown_seconds: 45,
        max_executions_per_player: 3,
        escalation_window_seconds: 600
      }

      assert Form.limits_sentence(rule) ==
               "Each player can trigger this at most 3× per day, at least 45 s apart; " <>
                 "repeat offences within 10 min escalate to the next action."

      assert Form.limits_sentence(%Rule{
               cooldown_seconds: 0,
               max_executions_per_player: 0,
               escalation_window_seconds: 0
             }) == "No limits: this fires every time its conditions hold."
    end
  end

  describe "placeholders" do
    test "an unknown placeholder is a validation error" do
      changeset =
        build(%{
          "actions" => [
            %{"type" => "message_player", "parameters" => %{"message" => "Hi {player_nmae}"}}
          ]
        })

      assert %{actions: [message]} = errors_on(changeset)
      assert message =~ "{player_nmae}"
    end

    test "an event placeholder is only valid for the trigger that carries it" do
      message = %{"type" => "message_player", "parameters" => %{"message" => "Nice {weapon}"}}

      assert %{actions: [_message]} = errors_on(build(%{"actions" => [message]}))

      assert build(%{"trigger_event" => "player_kill", "actions" => [message]}).valid?
    end

    test "leaderboard and progression placeholders are known" do
      changeset =
        build(%{
          "actions" => [
            %{
              "type" => "message_player",
              "parameters" => %{"message" => "{top_kills} {season_rank}"}
            }
          ]
        })

      assert changeset.valid?
    end
  end

  describe "most used fields" do
    test "falls back to a curated list, then learns from the rules" do
      assert Rules.most_used_fields() != []

      for _ <- 1..2,
          do: rule_fixture(%{conditions: [%{field: :squad_size, operator: :equal, value: "1"}]})

      rule_fixture(%{conditions: [%{field: :kills, operator: :equal, value: "1"}]})

      assert [:squad_size, :kills] = Rules.most_used_fields()
    end
  end
end
