defmodule HllConditionalActions.Games.Hll do
  @moduledoc """
  Reference data for Hell Let Loose (WW2), CRCON's `hll` game profile.

  Role values are the lowercased internal names the game server reports, which
  is exactly what CRCON's `get_detailed_players` returns in the `role` field
  (see `Roles` in `rcon/types.py`).
  """

  @behaviour HllConditionalActions.Games.Profile

  alias HllConditionalActions.Games.Profile

  @roles [
    {"rifleman", "Rifleman", :infantry, false},
    {"assault", "Assault", :infantry, false},
    {"automaticrifleman", "Automatic Rifleman", :infantry, false},
    {"medic", "Medic", :infantry, false},
    {"support", "Support", :infantry, false},
    {"heavymachinegunner", "Machine Gunner", :infantry, false},
    {"antitank", "Anti-Tank", :infantry, false},
    {"engineer", "Engineer", :infantry, false},
    {"officer", "Officer", :infantry, true},
    {"spotter", "Spotter", :recon, true},
    {"sniper", "Sniper", :recon, false},
    {"crewman", "Crewman", :armor, false},
    {"tankcommander", "Tank Commander", :armor, true},
    {"artilleryobserver", "Artillery Observer", :artillery, false},
    {"operator", "Operator", :artillery, false},
    {"gunner", "Gunner", :artillery, false},
    {"armycommander", "Commander", :commander, true}
  ]

  @teams [
    {"allies", "Allies"},
    {"axis", "Axis"}
  ]

  @game_modes [
    {"warfare", "Warfare"},
    {"offensive", "Offensive"},
    {"conquest", "Conquest"},
    {"skirmish", "Skirmish"},
    {"phased", "Phased"},
    {"majority", "Majority"}
  ]

  @profile %Profile{
    id: :hll,
    label: "Hell Let Loose",
    short_label: "HLL",
    role_types: [:infantry, :recon, :armor, :artillery, :commander],
    roles:
      Enum.map(@roles, fn {value, label, type, squad_leader?} ->
        %{value: value, label: label, type: type, squad_leader?: squad_leader?}
      end),
    teams: Enum.map(@teams, fn {value, label} -> %{value: value, label: label} end),
    game_modes: Enum.map(@game_modes, fn {value, label} -> %{value: value, label: label} end)
  }

  @impl Profile
  def profile, do: @profile
end
