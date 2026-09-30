defmodule HllConditionalActions.Rules.ConditionRunsTest do
  @moduledoc """
  Long rules fold their repeated conditions into lists for the pages, and
  the lists that can never hold are found for the health check. Shaped
  after two real rules: a K/D check followed by ninety `weapon is not`
  rows, and sixteen `message is` rows joined by *and*.
  """

  use ExUnit.Case, async: true

  alias HllConditionalActions.Rules.Condition
  alias HllConditionalActions.Rules.ConditionRuns

  doctest ConditionRuns

  # 86 weapons, the first four written twice: 90 rows.
  defp weapons do
    names = for n <- 1..86, do: "WEAPON #{n} [VARIANT #{n}]"
    {first, rest} = Enum.split(names, 4)
    Enum.flat_map(first, &[&1, &1]) ++ rest
  end

  defp kd_rule_conditions do
    [%Condition{field: :kill_death_ratio, operator: :greater_than, value: "3"}] ++
      Enum.map(weapons(), &%Condition{field: :weapon, operator: :not_equal, value: &1})
  end

  defp chat_rule_conditions do
    words = ~w(vtnc desgraçado preto macaco mono mono vsf bicha sfd vtmnc a b c d e f)
    Enum.map(words, &%Condition{field: :message_content, operator: :equal, value: &1})
  end

  describe "fold/2" do
    test "ninety weapon rows joined by and read as one list of 86" do
      [kd, list] = ConditionRuns.fold(kd_rule_conditions(), :and)

      assert kd.reading == :single
      assert kd.field == :kill_death_ratio

      assert list.reading == :none_of
      assert list.joiner == :and
      assert length(list.members) == 90
      assert length(list.values) == 86
      assert hd(list.values) == "WEAPON 1 [VARIANT 1]"
      assert list.counts["WEAPON 1 [VARIANT 1]"] == 2
      assert list.counts["WEAPON 5 [VARIANT 5]"] == 1
      # members keep their place in the rule
      assert list.members |> hd() |> elem(1) == 1
    end

    test "equal rows joined by or read as one of the list" do
      [run] = ConditionRuns.fold(chat_rule_conditions(), :or)

      assert run.reading == :one_of
      assert length(run.values) == 15
    end

    test "equal rows joined by and are a list that must hold all at once" do
      [run] = ConditionRuns.fold(chat_rule_conditions(), :and)

      assert run.reading == :all_at_once
      assert length(run.members) == 16
    end

    test "only consecutive rows on the same field and operator fold" do
      conditions = [
        %Condition{field: :weapon, operator: :not_equal, value: "A"},
        %Condition{field: :player_level, operator: :greater_than, value: "10"},
        %Condition{field: :weapon, operator: :not_equal, value: "B"},
        %Condition{field: :weapon, operator: :equal, value: "C"}
      ]

      assert conditions |> ConditionRuns.fold(:and) |> Enum.map(& &1.reading) ==
               [:single, :single, :single, :single]
    end

    test "numeric bounds and nand/nor rules are left alone" do
      bounds = [
        %Condition{field: :kills, operator: :greater_than, value: "3"},
        %Condition{field: :kills, operator: :greater_than, value: "5"}
      ]

      assert length(ConditionRuns.fold(bounds, :and)) == 2

      nor = [
        %Condition{field: :weapon, operator: :equal, value: "A"},
        %Condition{field: :weapon, operator: :equal, value: "B"}
      ]

      assert length(ConditionRuns.fold(nor, :nor)) == 2
    end

    test "one value repeated folds into a single" do
      conditions = [
        %Condition{field: :message_content, operator: :equal, value: "mono"},
        %Condition{field: :message_content, operator: :equal, value: "mono"}
      ]

      assert [%{reading: :single, values: ["mono"], counts: %{"mono" => 2}}] =
               ConditionRuns.fold(conditions, :and)
    end

    test "rows in different condition groups never fold together" do
      conditions = [
        %Condition{field: :weapon, operator: :not_equal, value: "A", group: 0},
        %Condition{field: :weapon, operator: :not_equal, value: "B", group: 1}
      ]

      assert length(ConditionRuns.fold(conditions, :or)) == 2
    end

    test "a group's own operator decides how its rows read" do
      conditions = [
        %Condition{field: :player_level, operator: :greater_than, value: "1", group: 0},
        %Condition{field: :weapon, operator: :equal, value: "A", group: 1, group_operator: :or},
        %Condition{field: :weapon, operator: :equal, value: "B", group: 1, group_operator: :or}
      ]

      assert [_level, %{reading: :one_of, joiner: :or}] = ConditionRuns.fold(conditions, :and)
    end
  end

  describe "contradictions/2" do
    test "the chat rule joined by and can never hold" do
      assert [%{field: :message_content, count: 16, values: values}] =
               ConditionRuns.contradictions(chat_rule_conditions(), :and)

      assert length(values) == 15
    end

    test "joined by or, or asking one value, it is fine" do
      assert ConditionRuns.contradictions(chat_rule_conditions(), :or) == []

      same = [
        %Condition{field: :message_content, operator: :equal, value: "mono"},
        %Condition{field: :message_content, operator: :equal, value: "mono"}
      ]

      assert ConditionRuns.contradictions(same, :and) == []
    end

    test "the weapon rule is not a contradiction" do
      assert ConditionRuns.contradictions(kd_rule_conditions(), :and) == []
    end

    test "found within an and group of a grouped rule, apart or not" do
      conditions = [
        %Condition{field: :message_content, operator: :equal, value: "a", group: 0},
        %Condition{field: :player_level, operator: :greater_than, value: "1", group: 0},
        %Condition{field: :message_content, operator: :equal, value: "b", group: 0},
        %Condition{field: :message_content, operator: :equal, value: "c", group: 1}
      ]

      assert [%{field: :message_content, count: 2}] =
               ConditionRuns.contradictions(conditions, :or)
    end
  end
end
