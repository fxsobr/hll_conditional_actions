defmodule HllConditionalActions.Engine.SamplesTest do
  use ExUnit.Case, async: true

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Engine.Context
  alias HllConditionalActions.Engine.Samples
  alias HllConditionalActions.Rules.Condition
  alias HllConditionalActions.Rules.Rule
  alias HllConditionalActions.Servers.Server

  # The table is shared by every test, so each one gets servers nobody else
  # records against.
  defp server(attrs \\ %{}) do
    struct(%Server{id: System.unique_integer([:positive]), name: "EU", game: :hll}, attrs)
  end

  defp record(server, trigger, player) do
    server
    |> Context.build(trigger, player: player)
    |> Samples.record()
  end

  defp rule(conditions, attrs \\ %{}) do
    struct(
      %Rule{
        trigger_event: :player_kill,
        logical_operator: :and,
        game: :hll,
        conditions: conditions
      },
      attrs
    )
  end

  test "keeps samples per server and trigger, newest first" do
    server = server()
    record(server, :player_kill, player(%{"name" => "First"}))
    record(server, :player_kill, player(%{"name" => "Second"}))
    record(server, :player_death, player(%{"name" => "Elsewhere"}))

    assert [%{player_name: "Second"}, %{player_name: "First"}] =
             Samples.list([server.id], :player_kill)
  end

  test "never keeps more than its capacity" do
    server = server()

    for level <- 1..(Samples.capacity() + 20) do
      record(server, :player_kill, player(%{"level" => level}))
    end

    assert length(Samples.list([server.id], :player_kill)) == Samples.capacity()
  end

  test "replays a rule and says which condition held events back" do
    server = server()
    for kills <- [1, 5, 20, 30], do: record(server, :player_kill, player(%{"kills" => kills}))

    result =
      [%Condition{field: :kills, operator: :greater_than, value: "10"}]
      |> rule()
      |> Samples.replay([server])

    assert %{total: 4, matched: 2, conditions: [%{field: :kills, failed: 2}]} = result
    assert length(result.examples) == 4
  end

  test "counts the outcomes an edit changes" do
    server = server()
    for kills <- [1, 5, 20, 30], do: record(server, :player_kill, player(%{"kills" => kills}))

    saved = rule([%Condition{field: :kills, operator: :greater_than, value: "10"}])
    edited = rule([%Condition{field: :kills, operator: :greater_than, value: "3"}])

    assert %{matched: 3, changed: 1} = Samples.replay(edited, [server], compare_to: saved)
  end

  test "only replays the servers it is given" do
    mine = server()
    theirs = server()
    record(mine, :player_kill, player())
    record(theirs, :player_kill, player())

    assert %{total: 1} = [%Condition{field: :always_true}] |> rule() |> Samples.replay([mine])
  end
end
