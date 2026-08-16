defmodule HllConditionalActions.Games.Hllv do
  @moduledoc """
  Reference data for Hell Let Loose: Vietnam, CRCON's `hllv` game profile.

  Vietnam replaces WW2's artillery roles with a mortar team, adds helicopter
  crew roles, and renames the squad leader (`officer` becomes `squadleader`).
  Its teams are South and North rather than Allies and Axis, although CRCON
  keeps reporting them under the `allies` / `axis` keys of the game state.
  """

  @behaviour HllConditionalActions.Games.Profile

  alias HllConditionalActions.Games.Profile

  @roles [
    {"rifleman", "Rifleman", :infantry, false},
    {"medic", "Medic", :infantry, false},
    {"specialist", "Specialist", :infantry, false},
    {"heavymachinegunner", "Machine Gunner", :infantry, false},
    {"grenadier", "Grenadier", :infantry, false},
    {"engineer", "Engineer", :infantry, false},
    {"squadleader", "Squad Leader", :infantry, true},
    {"spotter", "Spotter", :recon, true},
    {"sniper", "Sniper", :recon, false},
    {"crewman", "Crewman", :armor, false},
    {"tankcommander", "Tank Commander", :armor, true},
    {"mortarsupport", "Support", :mortar, false},
    {"mortarobserver", "Observer", :mortar, false},
    {"mortargunner", "Gunner", :mortar, false},
    {"helicopterpilot", "Pilot", :helicopter, false},
    {"helicopterlogisticsofficer", "Logistics Officer", :helicopter, false},
    {"armycommander", "Commander", :commander, true}
  ]

  # CRCON reports Vietnam's factions under the same `allies` / `axis` game state
  # keys as WW2, so the values stay stable while the labels follow the game.
  @teams [
    {"allies", "South"},
    {"axis", "North"}
  ]

  @game_modes [
    {"warfare", "Warfare"},
    {"offensive", "Offensive"},
    {"conquest", "Conquest"},
    {"domination", "Domination"}
  ]

  @profile %Profile{
    id: :hllv,
    label: "Hell Let Loose: Vietnam",
    short_label: "HLLV",
    role_types: [:infantry, :recon, :armor, :mortar, :helicopter, :commander],
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
