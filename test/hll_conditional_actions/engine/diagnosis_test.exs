defmodule HllConditionalActions.Engine.DiagnosisTest do
  use HllConditionalActions.DataCase, async: true

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Engine.Context
  alias HllConditionalActions.Engine.Diagnosis
  alias HllConditionalActions.Engine.SavedEvents
  alias HllConditionalActions.Engine.Simulator
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.RecipeAnswers
  alias HllConditionalActions.Rules.Recipes

  doctest RecipeAnswers

  defp context(server, trigger, attrs \\ %{}) do
    Context.build(server, trigger, player: player(attrs))
  end

  defp sample(server, trigger, attrs) do
    player = player(attrs)

    %{
      server_id: server.id,
      trigger: trigger,
      player_id: player["player_id"],
      player_name: player["name"],
      player: player,
      player_profile: nil,
      gamestate: nil,
      squad: %{},
      ranks: %{},
      event: nil,
      at: Map.get(attrs, :at, DateTime.utc_now()),
      at_us: System.os_time(:microsecond)
    }
  end

  describe "saved events" do
    test "keeps only the latest per server and trigger, and filters by player" do
      server = server_fixture()
      base = ~U[2026-09-01 10:00:00.000000Z]

      samples =
        for n <- 1..(SavedEvents.keep() + 5) do
          sample(server, :player_kill, %{"name" => "P#{n}", at: DateTime.add(base, n)})
        end

      SavedEvents.store(samples)
      SavedEvents.store([sample(server, :player_death, %{"name" => "Other"})])

      kept = SavedEvents.list([server.id], trigger: :player_kill, limit: 500)
      assert length(kept) == SavedEvents.keep()
      assert hd(kept).sample.player_name == "P#{SavedEvents.keep() + 5}"
      assert hd(kept).sample.trigger == :player_kill

      assert [event] = SavedEvents.list([server.id], player: "other")
      assert SavedEvents.get([server.id], event.id).sample.player_name == "Other"
      assert SavedEvents.get([server.id + 1], event.id) == nil
    end
  end

  describe "diagnose/3" do
    setup do
      %{server: server_fixture()}
    end

    test "reports each condition with actual against expected", %{server: server} do
      rule =
        rule_fixture(%{
          trigger_event: :player_kill,
          conditions: [%{field: :player_level, operator: :greater_than, value: "50"}]
        })

      diagnosis = Diagnosis.diagnose(rule, context(server, :player_kill, %{"level" => 42}))

      assert diagnosis.outcome == :conditions_not_met
      assert [%{actual: 42, expected: "50", result: false}] = diagnosis.conditions
      assert [%{type: :message_player, detail: "Welcome!"}] = diagnosis.actions
    end

    test "stops at the first failing step, in the engine's order", %{server: server} do
      rule = rule_fixture(%{trigger_event: :player_kill, exemptions: %{exempt_vip: true}})
      vip = context(server, :player_kill, %{"is_vip" => true})

      assert Diagnosis.diagnose(rule, vip).outcome == :exempt
      assert Diagnosis.diagnose(%{rule | enabled: false}, vip).outcome == :disabled
      assert Diagnosis.diagnose(rule, context(server, :player_death)).outcome == :wrong_trigger
      assert Diagnosis.diagnose(rule, context(server, :player_kill)).outcome == :fires
    end

    test "replays the cooldown as it stood when the event arrived", %{server: server} do
      rule = rule_fixture(%{trigger_event: :player_kill, cooldown_seconds: 600})
      ctx = context(server, :player_kill)
      fired_at = ~U[2026-09-01 10:00:00.000000Z]

      {:ok, execution} =
        Rules.record_execution(%{
          rule_id: rule.id,
          server_id: server.id,
          player_id: ctx.player_id,
          player_name: ctx.player_name,
          trigger_event: "player_kill",
          status: :executed,
          results: [],
          executed_at: fired_at
        })

      assert Diagnosis.diagnose(rule, ctx, at: DateTime.add(fired_at, 60)).outcome == :cooldown
      assert Diagnosis.diagnose(rule, ctx, at: DateTime.add(fired_at, 700)).outcome == :fires
      assert Diagnosis.diagnose(rule, ctx, limits: false).limits == :not_checked

      assert Diagnosis.execution_for(rule, ctx.player_id, DateTime.add(fired_at, -1)).id ==
               execution.id

      assert Diagnosis.execution_for(rule, ctx.player_id, DateTime.add(fired_at, 300)) == nil
    end
  end

  describe "simulate/2" do
    test "lists the rules that fire in priority order and flags conflicts" do
      server = server_fixture()

      kick =
        rule_fixture(%{
          name: "Kick",
          priority: 10,
          trigger_event: :player_team_kill,
          actions: [%{type: :kick_player, parameters: %{"reason" => "TK"}}]
        })

      punish =
        rule_fixture(%{
          name: "Punish",
          priority: 5,
          trigger_event: :player_team_kill,
          actions: [
            %{type: :message_player, parameters: %{"message" => "Careful"}},
            %{type: :punish_player, parameters: %{"reason" => "TK"}}
          ]
        })

      other = rule_fixture(%{trigger_event: :player_kill})

      %{results: results, conflicts: conflicts} =
        Simulator.simulate([punish, kick, other], context(server, :player_team_kill))

      assert Enum.map(results, & &1.rule.name) == ["Kick", "Punish"]
      assert Enum.all?(results, &(&1.diagnosis.outcome == :fires))

      kinds = Enum.map(conflicts, & &1.kind)
      assert :double_punishment in kinds
      assert :message_then_removed in kinds
    end
  end

  describe "recipe answers" do
    test "fill the recipe the wizard creates" do
      recipe = Recipes.fetch(:no_squad_leader)
      attrs = Recipes.to_attrs(recipe, name: "x")
      defaults = RecipeAnswers.defaults(recipe, attrs)
      assert defaults == %{min_players: 40, final_action: :punish_player}

      answers =
        RecipeAnswers.cast(recipe, defaults, %{"min_players" => "999", "final_action" => "nope"})

      assert answers == %{min_players: 100, final_action: :punish_player}

      applied =
        RecipeAnswers.apply(attrs, recipe, %{min_players: 20, final_action: :kick_player})

      assert Enum.at(applied.conditions, 2).value == "20"
      assert List.last(applied.actions).type == :kick_player
      assert {:ok, _rule} = Rules.create_rule(applied)
    end
  end
end
