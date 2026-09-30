defmodule HllConditionalActionsWeb.NumberFormatTest do
  use ExUnit.Case, async: true

  alias HllConditionalActionsWeb.NumberFormat

  doctest NumberFormat

  test "Spanish and Portuguese group with dots, English with commas" do
    for {locale, expected} <- [{"es", "1.284,5"}, {"pt_BR", "1.284,5"}, {"en", "1,284.5"}] do
      assert Gettext.with_locale(HllConditionalActionsWeb.Gettext, locale, fn ->
               NumberFormat.decimal(1284.5, 1)
             end) == expected
    end
  end

  test "keeps the sign of small negative numbers" do
    assert Gettext.with_locale(HllConditionalActionsWeb.Gettext, "en", fn ->
             NumberFormat.decimal(-0.5, 1)
           end) == "-0.5"
  end
end
