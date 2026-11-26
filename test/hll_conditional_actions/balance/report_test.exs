defmodule HllConditionalActions.Balance.ReportTest do
  use ExUnit.Case, async: true

  alias HllConditionalActions.Balance.Report

  @t0 ~U[2026-11-20 20:00:00Z]

  # A match starting `start` minutes in, lasting `length`, with players
  # "p1".."pN" (all of them playing ten minutes or more).
  defp match(id, start, length, map, {allied, axis}, players, opts \\ []) do
    ids = for i <- players, do: "p#{i}"

    %{
      server_id: Keyword.get(opts, :server, 1),
      id: id,
      map: map,
      mode: Keyword.get(opts, :mode, "warfare"),
      started_at: DateTime.add(@t0, start, :minute),
      ended_at: DateTime.add(@t0, start + length, :minute),
      allied: allied,
      axis: axis,
      players: ids,
      stayed: ids
    }
  end

  test "what each kind of match keeps for the next one" do
    report =
      Report.build([
        # a fast stomp, after which half the players leave
        match("1", 0, 20, "Foy", {5, 0}, 1..80),
        match("2", 25, 70, "Kursk", {3, 2}, 41..100),
        # a close match, after which everybody stays
        match("3", 100, 60, "Driel", {2, 3}, 41..100),
        match("4", 165, 60, "Foy", {4, 1}, 41..100)
      ])

    assert report.matches == 4
    assert report.linked == 3

    fast = Enum.find(report.kinds, &(&1.kind == :fast_stomp))
    assert fast.matches == 1
    assert fast.retention == 0.5
    assert fast.next_delta == -20

    close = Enum.find(report.kinds, &(&1.kind == :close))
    assert close.matches == 2
    assert close.retention == 1.0
    assert close.next_delta == 0
  end

  test "maps played the least are compared with the rest" do
    common =
      for i <- 0..39 do
        match("c#{i}", i * 65, 60, "Foy", {3, 2}, 1..80)
      end

    # Driel: played once, half the server leaves after it.
    rare = [
      match("r", 40 * 65, 60, "Driel", {3, 2}, 1..80),
      match("after", 40 * 65 + 65, 60, "Foy", {3, 2}, 41..80)
    ]

    report = Report.build(common ++ rare)

    assert report.rare.maps == 1
    assert report.rare.rare.matches == 1
    assert report.rare.rare.retention == 0.5
    assert report.rare.common.retention == 1.0

    assert [%{map: "Foy"} | _] = report.maps
    assert Enum.find(report.maps, &(&1.map == "Driel")).share < 0.03
  end

  test "each match is held against the others that ended at the same hour" do
    # Five evenings, the first match ending at 20:30 each day. On the first
    # the 5-0 is followed by 40 fewer players; on the others, by as many.
    report =
      Report.build(
        for day <- 0..4, {id, start, length, score, players} <- evening(day) do
          match("#{day}-#{id}", start, length, "Foy", score, players)
        end
      )

    fast = Enum.find(report.kinds, &(&1.kind == :fast_stomp))
    close = Enum.find(report.kinds, &(&1.kind == :close))

    assert fast.delta_vs == -40
    # Each close evening against the other four: 0 - (-40 / 4)
    assert close.delta_vs == 10
  end

  defp evening(0), do: [{"a", 0, 30, {5, 0}, 1..80}, {"b", 35, 60, {3, 2}, 1..40}]

  defp evening(day),
    do: [{"a", day * 1440, 30, {3, 2}, 1..80}, {"b", day * 1440 + 35, 60, {3, 2}, 1..80}]

  test "the players at a time count, when known" do
    [first, second] = [
      match("1", 0, 60, "Foy", {3, 2}, 1..80),
      match("2", 65, 60, "Foy", {3, 2}, 1..80)
    ]

    report = Report.build([Map.put(first, :average, 70), Map.put(second, :average, 60)])
    assert [close] = Enum.filter(report.kinds, &(&1.matches > 0))
    assert close.population == 70
    assert close.next_delta == -10
  end

  test "matches on another server, or hours apart, are not paired" do
    report =
      Report.build([
        match("1", 0, 30, "Foy", {5, 0}, 1..60),
        match("2", 35, 30, "Foy", {5, 0}, 1..60, server: 2),
        match("3", 300, 30, "Foy", {5, 0}, 1..60)
      ])

    assert report.linked == 0
  end
end
