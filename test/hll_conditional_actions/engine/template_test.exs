defmodule HllConditionalActions.Engine.TemplateTest do
  use ExUnit.Case, async: true

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Engine.Context
  alias HllConditionalActions.Engine.Template
  alias HllConditionalActions.Servers.Server

  doctest HllConditionalActions.Engine.Template

  @server %Server{id: 1, name: "EU Warfare #1", game: :hll}

  describe "render/2" do
    setup do
      context =
        Context.build(@server, :periodic,
          player: player(%{"name" => "Chris", "level" => 42, "role" => "heavymachinegunner"}),
          gamestate: gamestate()
        )

      %{context: context}
    end

    test "fills placeholders from the context", %{context: context} do
      assert Template.render("Hi {player_name}, level {player_level}", context) ==
               "Hi Chris, level 42"
    end

    test "translates the role through the game profile", %{context: context} do
      assert Template.render("{player_role}", context) == "Machine Gunner"
    end

    test "exposes match and server values", %{context: context} do
      assert Template.render("{map_name} on {server_name} ({server_player_count})", context) ==
               "Carentan on EU Warfare #1 (49)"
    end

    test "renders booleans as words rather than true/false", %{context: context} do
      assert Template.render("VIP: {is_vip}", context) == "VIP: no"
    end

    test "leaves an unknown placeholder visible so the typo is obvious", %{context: context} do
      assert Template.render("Hi {player_nmae}", context) == "Hi {player_nmae}"
    end

    test "a missing value renders as empty rather than nil" do
      context = Context.build(@server, :periodic, player: nil)

      assert Template.render("[{player_name}]", context) == "[]"
    end

    test "nil templates render as an empty string", %{context: context} do
      assert Template.render(nil, context) == ""
    end
  end

  describe "placeholders/1" do
    test "lists the placeholders a template uses, without duplicates" do
      assert Template.placeholders("{a} {b} {a}") == ["a", "b"]
    end

    test "ignores text that is not a placeholder" do
      assert Template.placeholders("100% {ok} {Not-A-Var}") == ["ok"]
    end
  end
end
