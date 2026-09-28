defmodule HllConditionalActions.Crcon.GameTextTest do
  use ExUnit.Case, async: true

  doctest HllConditionalActions.Crcon.GameText

  alias HllConditionalActions.Crcon.GameText

  test "flags, skin tones and joined emoji leave nothing behind" do
    assert GameText.clean("GG 🇧🇷 👍🏽 👨‍👩‍👧 ❤️") == "GG"
  end

  test "an emoji-only text becomes empty" do
    assert GameText.clean("🎉🎉") == ""
  end
end
