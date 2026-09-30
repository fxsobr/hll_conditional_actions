defmodule HllConditionalActionsWeb.ConditionGroupsViewTest do
  @moduledoc """
  A long rule in words: the folded lists as chips, the short line of the
  rules list, and what a version added to a list.
  """

  use ExUnit.Case, async: true

  alias HllConditionalActions.Rules.Condition
  alias HllConditionalActions.Rules.Rule
  alias HllConditionalActionsWeb.ConditionGroupsView
  alias HllConditionalActionsWeb.RuleComponents

  defp weapons(count) do
    names = for n <- 1..count, do: "WEAPON #{n} [VARIANT #{n}]"
    {first, rest} = Enum.split(names, 4)
    Enum.flat_map(first, &[&1, &1]) ++ rest
  end

  defp kd_rule(weapon_count \\ 86) do
    %Rule{
      game: :hll,
      trigger_event: :player_team_kill,
      logical_operator: :and,
      escalation_window_seconds: 0,
      actions: [],
      conditions:
        [%Condition{field: :kill_death_ratio, operator: :greater_than, value: "3"}] ++
          Enum.map(
            weapons(weapon_count),
            &%Condition{field: :weapon, operator: :not_equal, value: &1}
          )
    }
  end

  defp chat_rule do
    words = ~w(vtnc desgraçado preto macaco mono mono vsf bicha sfd vtmnc a b c d e f)

    %Rule{
      game: :hll,
      trigger_event: :player_chat,
      logical_operator: :and,
      escalation_window_seconds: 0,
      actions: [],
      conditions:
        Enum.map(words, &%Condition{field: :message_content, operator: :equal, value: &1})
    }
  end

  test "the weapon list reads as one chip with its first names" do
    [kd, list] = ConditionGroupsView.for_rule(kd_rule())

    refute kd.list?
    assert kd.text == "K/D ratio is greater than 3"

    assert list.list?
    assert list.text == "Weapon is none of 86 weapons"
    assert list.preview == "WEAPON 1, WEAPON 2, +84"

    assert ConditionGroupsView.full_text(list) ==
             "Weapon is none of 86 weapons (WEAPON 1, WEAPON 2, +84)"

    assert length(list.items) == 86
    assert %{label: "WEAPON 1 [VARIANT 1]", count: 2} = hd(list.items)
    assert ConditionGroupsView.members_text(list) == "90 conditions · 4 repeated"
  end

  test "equal rows joined by and read as a value that must be all of them" do
    [entry] = ConditionGroupsView.for_rule(chat_rule())

    assert entry.reading == :all_at_once
    assert entry.text == "Chat message is at the same time vtnc, desgraçado and +13"
  end

  test "the same rows joined by or read as one of the list" do
    [entry] = ConditionGroupsView.for_rule(%{chat_rule() | logical_operator: :or})

    assert entry.text == "Chat message is one of 15 values"
  end

  test "keys line entries up across versions" do
    [_kd, before] = ConditionGroupsView.for_rule(kd_rule(22))
    [_kd, now] = ConditionGroupsView.for_rule(kd_rule())

    assert before.key == now.key
    assert ConditionGroupsView.delta_text(before, now) == "+64 weapons"
    assert ConditionGroupsView.delta_text(now, before) == "−64 weapons"
    assert ConditionGroupsView.delta_text(now, now) == nil

    items = ConditionGroupsView.diff_items(before, now)
    assert length(items) == 86
    assert Enum.count(items, &(&1.mark == :added)) == 64
    assert hd(items).mark == :added
  end

  test "the rules list names both entries of a folded rule" do
    assert RuleComponents.short_sentence(kd_rule()) =~
             "K/D ratio is greater than 3 · weapon is none of 86 weapons"
  end

  test "the sentence caps its conditions" do
    conditions =
      for n <- 1..10,
          do: %Condition{field: :player_level, operator: :greater_than, value: "#{n}"}

    parts = RuleComponents.sentence_parts(%{kd_rule() | conditions: conditions}, cap: 8)

    assert [{:more, 2, hidden}] = Enum.filter(parts, &match?({:more, _, _}, &1))
    assert Enum.count(hidden, &match?({:chip, _}, &1)) == 2
  end
end
