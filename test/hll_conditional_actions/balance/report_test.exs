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
