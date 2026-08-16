defmodule HllConditionalActions.Rules.RecipesTest do
  @moduledoc """
  A recipe is the first rule most admins will ever run, so every one of them
  has to survive the real changeset — a template that cannot be saved is
  worse than no template — and none of them may reach the game before it has
  been read.
  """

  use HllConditionalActions.DataCase, async: true

  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Recipes

  defp attrs(recipe) do
    Recipes.to_attrs(recipe, name: "Test #{recipe.id}", game: :hll)
  end

  test "every recipe produces a rule the changeset accepts" do
    for recipe <- Recipes.all() do
      changeset = Rules.change_rule(%Rules.Rule{}, attrs(recipe))

      assert changeset.valid?, "#{recipe.id}: #{inspect(changeset.errors)}"
    end
  end

  test "every recipe actually saves" do
    for recipe <- Recipes.all() do
      assert {:ok, rule} = Rules.create_rule(attrs(recipe))
      assert rule.name == "Test #{recipe.id}"
    end
  end

  test "every recipe starts in simulation, so accepting one cannot punish anybody" do
    for recipe <- Recipes.all() do
      assert attrs(recipe).simulation, "#{recipe.id} would reach the game immediately"
    end
  end

  test "recipes only reference vocabulary this build has" do
    fields = Rules.Catalog.fields()
    actions = Rules.Catalog.action_types()

    for recipe <- Recipes.all() do
      built = attrs(recipe)

      assert Enum.all?(built.conditions, &(&1.field in fields)),
             "#{recipe.id} has an unknown field"

      assert Enum.all?(built.actions, &(&1.type in actions)), "#{recipe.id} has an unknown action"
    end
  end

  test "the punishing recipes escalate rather than jumping to a kick" do
    for id <- [:no_squad_leader, :solo_tank, :team_kill_ladder] do
      built = id |> Recipes.fetch() |> attrs()

      assert built.escalation_window_seconds > 0, "#{id} should escalate"
      assert length(built.actions) > 1, "#{id} needs more than one rung"

      assert hd(built.actions).type == :message_player,
             "#{id} should open with a warning, not a punishment"
    end
  end

  test "fetch/1 takes an id in either shape, and answers nil for anything else" do
    assert Recipes.fetch(:welcome).id == :welcome
    assert Recipes.fetch("welcome").id == :welcome
    assert Recipes.fetch("nope") == nil
  end
end
