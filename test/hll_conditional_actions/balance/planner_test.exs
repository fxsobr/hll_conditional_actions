defmodule HllConditionalActions.Balance.PlannerTest do
  use ExUnit.Case, async: true

  alias HllConditionalActions.Balance.Planner

  doctest Planner

  defp squad(team, name, ratings) do
    for {rating, i} <- Enum.with_index(ratings, 1),
        do: %{id: "#{team}-#{name}-#{i}", team: team, squad: name, rating: rating}
  end

  # Allies: a strong squad and two average ones; axis: three weak ones.
  defp lopsided do
    squad(:allies, "able", [1400, 1380, 1350, 1300, 1300, 1290]) ++
      squad(:allies, "baker", [1000, 1000, 1000, 1000]) ++
      squad(:allies, "charlie", [1010, 990, 1000]) ++
      squad(:axis, "able", [900, 920, 880, 950, 900, 910]) ++
      squad(:axis, "baker", [950, 960, 940, 930]) ++
      squad(:axis, "charlie", [1000, 980, 990])
  end

  defp moved_ids(plan), do: plan.moves |> Enum.flat_map(& &1.players) |> MapSet.new(& &1.id)

  test "closes the gap by moving whole squads" do
    plan = Planner.plan(lopsided(), MapSet.new(), max_moves: 12, max_count_gap: 2)

    assert plan.gap > 100
    assert abs(plan.gap_after) < abs(plan.gap)
    assert plan.moves != []

    moved = moved_ids(plan)

    # A squad moves whole or not at all.
    for {_squad, members} <- Enum.group_by(lopsided(), &{&1.team, &1.squad}) do
      flags = members |> Enum.map(&MapSet.member?(moved, &1.id)) |> Enum.uniq()
      assert length(flags) == 1
    end
  end

  test "never moves more players than allowed" do
    plan = Planner.plan(lopsided(), MapSet.new(), max_moves: 3, max_count_gap: 6)
    assert MapSet.size(moved_ids(plan)) <= 3
  end

  test "keeps the head counts close" do
    plan = Planner.plan(lopsided(), MapSet.new(), max_moves: 20, max_count_gap: 1)
    moved = moved_ids(plan)

    counts =
      lopsided()
      |> Enum.map(fn p ->
        cond do
          not MapSet.member?(moved, p.id) -> p.team
          p.team == :allies -> :axis
          true -> :allies
        end
      end)
      |> Enum.frequencies()

    assert abs(counts[:allies] - counts[:axis]) <= 1
  end

  test "frequent partners in two squads move together" do
    partners = MapSet.new([{"allies-able-1", "allies-baker-1"}])
    plan = Planner.plan(lopsided(), partners, max_moves: 20, max_count_gap: 3)
    moved = moved_ids(plan)

    assert MapSet.member?(moved, "allies-able-1") == MapSet.member?(moved, "allies-baker-1")
  end

  test "the commander's unit stays" do
    players =
      [%{id: "cmd", team: :allies, squad: "command", rating: 1500, movable?: false}] ++
        lopsided()

    plan = Planner.plan(players, MapSet.new(), max_moves: 20, max_count_gap: 3)
    refute MapSet.member?(moved_ids(plan), "cmd")
  end

  test "an even match moves nobody" do
    players = squad(:allies, "able", [1000, 1010]) ++ squad(:axis, "able", [1005, 1000])
    assert %{moves: []} = Planner.plan(players, MapSet.new())
  end
end
