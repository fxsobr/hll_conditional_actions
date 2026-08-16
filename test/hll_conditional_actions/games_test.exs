defmodule HllConditionalActions.GamesTest do
  use ExUnit.Case, async: true

  alias HllConditionalActions.Games
  alias HllConditionalActions.Games.Profile

  doctest HllConditionalActions.Games
  doctest HllConditionalActions.Games.Profile

  describe "profiles" do
    test "both games are registered" do
      assert Games.all() == [:hll, :hllv]
    end

    test "casts external values" do
      assert Games.cast("HLL") == {:ok, :hll}
      assert Games.cast("hllv") == {:ok, :hllv}
      assert Games.cast("quake") == :error
      assert Games.cast(nil) == :error
    end

    test "profile! raises on an unknown game" do
      assert_raise ArgumentError, ~r/unknown game/, fn -> Games.profile!("quake") end
    end
  end

  describe "role catalogs differ between the games" do
    test "WW2 has artillery roles that Vietnam does not" do
      hll = Games.profile!(:hll)
      hllv = Games.profile!(:hllv)

      assert "artilleryobserver" in role_values(hll)
      refute "artilleryobserver" in role_values(hllv)
    end

    test "Vietnam has helicopter and mortar roles that WW2 does not" do
      hll = Games.profile!(:hll)
      hllv = Games.profile!(:hllv)

      assert "helicopterpilot" in role_values(hllv)
      assert "mortargunner" in role_values(hllv)
      refute "helicopterpilot" in role_values(hll)
    end

    test "the squad leader role is named differently" do
      assert {:ok, %{label: "Officer"}} =
               Profile.fetch_role(Games.profile!(:hll), "officer")

      assert {:ok, %{label: "Squad Leader"}} =
               Profile.fetch_role(Games.profile!(:hllv), "squadleader")

      assert :error = Profile.fetch_role(Games.profile!(:hllv), "officer")
    end

    test "role lookup ignores casing, as CRCON lowercases what the server reports" do
      assert {:ok, %{value: "heavymachinegunner"}} =
               Profile.fetch_role(Games.profile!(:hll), "HeavyMachineGunner")
    end
  end

  describe "teams and game modes" do
    test "teams keep CRCON's keys but follow each game's naming" do
      assert Profile.team_options(Games.profile!(:hll)) == [
               {"Allies", "allies"},
               {"Axis", "axis"}
             ]

      assert Profile.team_options(Games.profile!(:hllv)) == [
               {"South", "allies"},
               {"North", "axis"}
             ]
    end

    test "only Vietnam supports domination, only WW2 supports skirmish" do
      hll_modes = mode_values(Games.profile!(:hll))
      hllv_modes = mode_values(Games.profile!(:hllv))

      assert "skirmish" in hll_modes
      refute "skirmish" in hllv_modes

      assert "domination" in hllv_modes
      refute "domination" in hll_modes
    end
  end

  defp role_values(profile), do: Enum.map(profile.roles, & &1.value)
  defp mode_values(profile), do: Enum.map(profile.game_modes, & &1.value)
end
