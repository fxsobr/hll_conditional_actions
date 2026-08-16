defmodule HllConditionalActions.Engine.ScheduleTest do
  @moduledoc """
  Time-of-day conditions read the server's own zone, so "after 22:00" means the
  players' evening rather than the machine's.
  """

  use ExUnit.Case, async: true

  alias HllConditionalActions.Engine.Context
  alias HllConditionalActions.Engine.Evaluator
  alias HllConditionalActions.Rules.Condition
  alias HllConditionalActions.Servers.Server

  defp context(timezone) do
    Context.build(%Server{id: 1, name: "S", game: :hll, timezone: timezone}, :periodic)
  end

  describe "hour_of_day" do
    test "is the local hour, not UTC" do
      utc = Evaluator.field_value(:hour_of_day, context("Etc/UTC"))
      sao_paulo = Evaluator.field_value(:hour_of_day, context("America/Sao_Paulo"))

      # São Paulo is UTC-3 all year (Brazil dropped daylight saving in 2019).
      assert sao_paulo == Integer.mod(utc - 3, 24)
    end

    test "two servers in different zones disagree about the hour" do
      tokyo = Evaluator.field_value(:hour_of_day, context("Asia/Tokyo"))
      los_angeles = Evaluator.field_value(:hour_of_day, context("America/Los_Angeles"))

      refute tokyo == los_angeles
    end

    test "an unknown zone falls back to UTC instead of failing the rule" do
      assert Evaluator.field_value(:hour_of_day, context("Mars/Olympus_Mons")) ==
               Evaluator.field_value(:hour_of_day, context("Etc/UTC"))
    end

    test "compares as a number" do
      hour = Evaluator.field_value(:hour_of_day, context("Etc/UTC"))

      assert holds?(:hour_of_day, :greater_than_or_equal, to_string(hour), context("Etc/UTC"))
      assert holds?(:hour_of_day, :less_than, to_string(hour + 1), context("Etc/UTC"))
    end
  end

  describe "day_of_week" do
    test "is the local day name" do
      day = Evaluator.field_value(:day_of_week, context("Etc/UTC"))

      assert day in ~w(monday tuesday wednesday thursday friday saturday sunday)
    end

    test "matches a list of days, which is how a weekend rule is written" do
      day = Evaluator.field_value(:day_of_week, context("Etc/UTC"))

      assert holds?(:day_of_week, :in_list, "#{day}, someotherday", context("Etc/UTC"))
      assert holds?(:day_of_week, :not_in_list, "someotherday", context("Etc/UTC"))
    end
  end

  describe "Context.day_name/1" do
    test "names every day of a known week" do
      names = for day <- 17..23, do: Context.day_name(Date.new!(2026, 8, day))

      assert names == ~w(monday tuesday wednesday thursday friday saturday sunday)
    end
  end

  defp holds?(field, operator, value, context) do
    Evaluator.evaluate_condition(
      %Condition{field: field, operator: operator, value: value},
      context
    )
  end
end
