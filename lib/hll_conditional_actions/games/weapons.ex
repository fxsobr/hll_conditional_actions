defmodule HllConditionalActions.Games.Weapons do
  @moduledoc """
  What kind of weapon a kill was made with, from the name HLL writes in the
  log line (`KILL: A(Allies/…) -> B(Axis/…) with M3 KNIFE`).

  The table is CRCON's own (`rcon/weapons.py`), with the categories an admin
  writes rules about. CRCON counts knives and spades as plain infantry
  weapons and has no melee type at all; here they are `:melee`, so "whoever
  kills with a knife or a spade" is one condition. Anti-tank rifles and
  launchers are `:anti_tank`, flamethrowers `:flamethrower`, and a vehicle
  named on its own - not one of its guns - is `:roadkill`.

  A name the table does not know - a weapon added after this was written,
  or one of Vietnam's, whose list lives in CRCON's `hllrcon` package - falls
  through to keyword rules ("KNIFE", "MACHETE", "GRENADE", "MINE", a gun in
  "[brackets]" is a vehicle's...), and to `:infantry` last.
  """

  @categories [
    :melee,
    :infantry,
    :machine_gun,
    :sniper,
    :grenade,
    :explosive,
    :anti_tank,
    :flamethrower,
    :at_gun,
    :artillery,
    :armor,
    :roadkill,
    :commander
  ]

  # From CRCON's rcon/weapons.py (MIT), by exact name.
  @crcon_table %{
    "105MM HOWITZER [M4A3 (105mm)]" => :armor,
    "122MM HOWITZER [M1938 (M-30)]" => :artillery,
    "150MM HOWITZER [sFH 18]" => :artillery,
    "152MM M-10T [KV-2]" => :armor,
    "155MM HOWITZER [M114]" => :artillery,
    "19-K 45MM [BA-10]" => :armor,
    "20MM KWK 30 [Sd.Kfz.121 Luchs]" => :armor,
    "230MM PETARD [Churchill Mk III A.V.R.E.]" => :armor,
    "37MM CANNON [M3 Stuart Honey]" => :armor,
    "37MM CANNON [Stuart M5A1]" => :armor,
    "45MM M1937 [T70]" => :armor,
    "50mm KwK 39/1 [Sd.Kfz.234 Puma]" => :armor,
    "57MM CANNON [M1 57mm]" => :armor,
    "57MM CANNON [ZiS-2]" => :at_gun,
    "60L (Supply)" => :armor,
    "60L (Transport)" => :armor,
    "7.5CM KwK 37 [Panzer III Ausf.N]" => :armor,
    "7.5CM KwK 37 [Sd.Kfz.161 Panzer IV]" => :armor,
    "75MM CANNON [PAK 40]" => :at_gun,
    "75MM CANNON [Sd.Kfz.161 Panzer IV]" => :armor,
    "75MM CANNON [Sd.Kfz.171 Panther]" => :armor,
    "75MM CANNON [Sherman M4A3(75)W]" => :armor,
    "75MM M3 GUN [Sherman M4A3E2]" => :armor,
    "76MM M1 GUN [Sherman M4A3E2(76)]" => :armor,
    "76MM ZiS-5 [T34/76]" => :armor,
    "88 KWK 36 L/56 [Sd.Kfz.181 Tiger 1]" => :armor,
    "A.P. Shrapnel Mine Mk II" => :explosive,
    "A.T. Mine G.S. Mk V" => :explosive,
    "BA-10" => :armor,
    "BAZOOKA" => :anti_tank,
    "Bedford OYD (Supply)" => :armor,
    "Bedford OYD (Transport)" => :armor,
    "Bishop SP 25pdr" => :armor,
    "BOMBING RUN" => :commander,
    "Boys Anti-tank Rifle" => :infantry,
    "Bren Gun" => :machine_gun,
    "BROWNING M1919" => :machine_gun,
    "Canadian Sten Mk.II" => :infantry,
    "Churchill Mk III A.V.R.E." => :armor,
    "Churchill Mk.III" => :armor,
    "COAXIAL BESA 7.92mm" => :armor,
    "COAXIAL BESA 7.92mm [Churchill Mk III A.V.R.E.]" => :armor,
    "COAXIAL BESA 7.92mm [Churchill Mk.III]" => :armor,
    "COAXIAL BESA 7.92mm [Churchill Mk.VII]" => :armor,
    "COAXIAL BESA 7.92mm [M4A3 (105mm)]" => :armor,
    "COAXIAL BESA [Cromwell]" => :armor,
    "COAXIAL BESA [Crusader Mk.III]" => :armor,
    "COAXIAL BESA [Daimler]" => :armor,
    "COAXIAL BESA [Tetrarch]" => :armor,
    "COAXIAL DT [BA-10]" => :armor,
    "COAXIAL DT [IS-1]" => :armor,
    "COAXIAL DT [T34/76]" => :armor,
    "COAXIAL DT [T70]" => :armor,
    "COAXIAL M1919 [Firefly]" => :armor,
    "COAXIAL M1919 [M3 Stuart Honey]" => :armor,
    "COAXIAL M1919 [M4A3 (105mm)]" => :armor,
    "COAXIAL M1919 [M8 Greyhound]" => :armor,
    "COAXIAL M1919 [Sherman M4A3(75)W]" => :armor,
    "COAXIAL M1919 [Sherman M4A3E2(76)]" => :armor,
    "COAXIAL M1919 [Sherman M4A3E2]" => :armor,
    "COAXIAL M1919 [Stuart M5A1]" => :armor,
    "COAXIAL MG34" => :armor,
    "COAXIAL MG34 [Panzer III Ausf.N]" => :armor,
    "COAXIAL MG34 [Sd.Kfz.121 Luchs]" => :armor,
    "COAXIAL MG34 [Sd.Kfz.161 Panzer IV]" => :armor,
    "COAXIAL MG34 [Sd.Kfz.171 Panther]" => :armor,
    "COAXIAL MG34 [Sd.Kfz.181 Tiger 1]" => :armor,
    "COAXIAL MG34 [Sd.Kfz.234 Puma]" => :armor,
    "COLT M1911" => :infantry,
    "Cromwell" => :armor,
    "D-5T 85MM [IS-1]" => :armor,
    "Daimler" => :armor,
    "DP-27" => :machine_gun,
    "Enfield No.2 Mk I" => :infantry,
    "Fairbairn–Sykes" => :infantry,
    "FELDSPATEN" => :infantry,
    "FG42" => :infantry,
    "FG42 x4" => :sniper,
    "Firefly" => :armor,
    "FLAMETHROWER" => :infantry,
    "FLAMMENWERFER 41" => :infantry,
    "FLARE GUN" => :infantry,
    "FN-Inglis No 2 MK I" => :infantry,
    "GAZ-67" => :armor,
    "GEWEHR 43" => :infantry,
    "GMC CCKW 353 (Supply)" => :armor,
    "GMC CCKW 363 (Supply)" => :armor,
    "GMC CCKW 363 (Transport)" => :armor,
    "Half-track" => :armor,
    "HULL BESA 7.92mm [Churchill Mk.III]" => :armor,
    "HULL BESA 7.92mm [Churchill Mk.VII]" => :armor,
    "HULL BESA 7.92mm [M4A3 (105mm)]" => :armor,
    "HULL BESA [Cromwell]" => :armor,
    "HULL DT [IS-1]" => :armor,
    "HULL DT [KV-2]" => :armor,
    "HULL DT [T34/76]" => :armor,
    "HULL M1919 [M4A3 (105mm)]" => :armor,
    "HULL M1919 [Sherman M4A3(75)W]" => :armor,
    "HULL M1919 [Sherman M4A3E2(76)]" => :armor,
    "HULL M1919 [Sherman M4A3E2]" => :armor,
    "HULL M1919 [Stuart M5A1]" => :armor,
    "HULL MG34 [Sd.Kfz.161 Panzer IV]" => :armor,
    "HULL MG34 [Sd.Kfz.171 Panther]" => :armor,
    "HULL MG34 [Sd.Kfz.181 Tiger 1]" => :armor,
    "IS-1" => :armor,
    "Jeep" => :armor,
    "Jeep Willys" => :armor,
    "KARABINER 98K" => :infantry,
    "KARABINER 98K W/ SCHIESSBECHER" => :infantry,
    "KARABINER 98K x8" => :sniper,
    "Kubelwagen" => :armor,
    "KV-2" => :armor,
    "Lanchester" => :infantry,
    "Lee-Enfield Pattern 1914" => :infantry,
    "Lee-Enfield Pattern 1914 Sniper" => :sniper,
    "Lee–Enfield Jungle Carbine" => :infantry,
    "Lee–Enfield No.4 Mk I" => :infantry,
    "Lewis Gun" => :machine_gun,
    "LUGER P08" => :infantry,
    "M1 CARBINE" => :infantry,
    "M1 GARAND" => :infantry,
    "M1 GARAND W/ M7 RGL" => :infantry,
    "M1903 SPRINGFIELD" => :sniper,
    "M1903A3 SPRINGFIELD" => :infantry,
    "M1903A4_SPRINGFIELD" => :sniper,
    "M1918A2 BAR" => :infantry,
    "M1919 SPRINGFIELD" => :sniper,
    "M1928A1 THOMPSON" => :infantry,
    "M1A1 AT MINE" => :explosive,
    "M1A1 THOMPSON" => :infantry,
    "M2 AP MINE" => :explosive,
    "M2 Browning [Half-track]" => :armor,
    "M2 Browning [M3 Half-track]" => :armor,
    "M2 FLAMETHROWER" => :infantry,
    "M24 STIELHANDGRANATE" => :grenade,
    "M3 GREASE GUN" => :infantry,
    "M3 Half-track" => :armor,
    "M3 KNIFE" => :infantry,
    "M3 Stuart Honey" => :armor,
    "M43 STIELHANDGRANATE" => :grenade,
    "M4A3 (105mm)" => :armor,
    "M6 37mm [M8 Greyhound]" => :armor,
    "M8 Greyhound" => :armor,
    "M97 TRENCH GUN" => :infantry,
    "MG 42 [Sd.Kfz 251 Half-track]" => :armor,
    "MG34" => :machine_gun,
    "MG42" => :machine_gun,
    "Mills Bomb" => :grenade,
    "MK2 GRENADE" => :grenade,
    "MOLOTOV" => :grenade,
    "MOSIN NAGANT 1891" => :infantry,
    "MOSIN NAGANT 91/30" => :infantry,
    "MOSIN NAGANT M38" => :infantry,
    "MP40" => :infantry,
    "MPL-50 SPADE" => :infantry,
    "NAGANT M1895" => :infantry,
    "No.2 Mk 5 Flare Pistol" => :infantry,
    "No.77" => :grenade,
    "No.82 Grenade" => :grenade,
    "Opel Blitz (Supply)" => :armor,
    "Opel Blitz (Transport)" => :armor,
    "OQF 57MM [Churchill Mk.III]" => :armor,
    "OQF 57MM [Crusader Mk.III]" => :armor,
    "OQF 57MM [Sturmpanzer IV]" => :armor,
    "OQF 6 - POUNDER Mk.V [Churchill Mk.III]" => :armor,
    "OQF 75MM [Churchill Mk.VII]" => :armor,
    "OQF 75MM [Cromwell]" => :armor,
    "Ordnance QF 6-pounder" => :at_gun,
    "Panzer III Ausf.N" => :armor,
    "PANZERSCHRECK" => :anti_tank,
    "PETARD 230MM  [M4A3 (105mm)]" => :armor,
    "PIAT" => :infantry,
    "POMZ AP MINE" => :explosive,
    "PPSH 41" => :infantry,
    "PPSH 41 W/DRUM" => :infantry,
    "PRECISION STRIKE" => :commander,
    "PTRS-41" => :infantry,
    "QF 17-POUNDER [Firefly]" => :armor,
    "QF 2-POUNDER [Daimler]" => :armor,
    "QF 2-POUNDER [Tetrarch]" => :armor,
    "QF 25 POUNDER [Bishop SP 25pdr]" => :armor,
    "QF 25-POUNDER [QF 25-Pounder]" => :artillery,
    "QF 6-POUNDER [QF 6-Pounder]" => :at_gun,
    "QF 75MM [Cromwell]" => :armor,
    "RG-42 GRENADE" => :grenade,
    "Rifle No.4 Mk I" => :infantry,
    "Rifle No.4 Mk I Sniper" => :sniper,
    "Rifle No.5 Mk I" => :infantry,
    "ROKS-2" => :infantry,
    "S-MINE" => :explosive,
    "Satchel" => :explosive,
    "SATCHEL" => :explosive,
    "SATCHEL CHARGE" => :explosive,
    "SCOPED MOSIN NAGANT 91/30" => :sniper,
    "SCOPED SVT40" => :sniper,
    "Sd.Kfz 251 Half-track" => :armor,
    "Sd.Kfz.121 Luchs" => :armor,
    "Sd.Kfz.161 Panzer IV" => :armor,
    "Sd.Kfz.171 Panther" => :armor,
    "Sd.Kfz.181 Tiger 1" => :armor,
    "Sd.Kfz.234 Puma" => :armor,
    "Sherman M4A3(75)W" => :armor,
    "Sherman M4A3E2" => :armor,
    "Sherman M4A3E2(76)" => :armor,
    "SMLE No.1 Mk III" => :infantry,
    "SMLE No.1 Mk III EY" => :infantry,
    "Sten Gun" => :infantry,
    "Sten Gun Mk.II" => :infantry,
    "Sten Gun Mk.V" => :infantry,
    "STG44" => :infantry,
    "STRAFING RUN" => :commander,
    "Stuart M5A1" => :armor,
    "StuH 43 L/12 [Sturmpanzer IV]" => :armor,
    "Sturmpanzer IV" => :armor,
    "SVT40" => :infantry,
    "T34/76" => :armor,
    "T70" => :armor,
    "TELLERMINE 43" => :explosive,
    "Tetrarch" => :armor,
    "TM-35 AT MINE" => :explosive,
    "TOKAREV TT33" => :infantry,
    "WALTHER P38" => :infantry,
    "Webley MK VI" => :infantry,
    "ZIS-5 (Supply)" => :armor,
    "ZIS-5 (Transport)" => :armor
  }

  # Checked before the table: CRCON files these as infantry weapons.
  @melee ~w(KNIFE SPADE FELDSPATEN FAIRBAIRN SHOVEL MACHETE BAYONET ENTRENCHING)
  @anti_tank ~w(BAZOOKA PANZERSCHRECK PIAT PTRS BOYS RPG M72 LAW)

  @doc "Every category, in display order."
  @spec categories() :: [atom()]
  def categories, do: @categories

  @doc """
  Every weapon we know by name, grouped by category in display order, each
  list sorted - what the rule builder offers to pick from. Vietnam's weapons
  are not listed (CRCON keeps them in a package, not in its source); a rule
  for them uses the categories or types the name in.

      iex> catalog = HllConditionalActions.Games.Weapons.catalog()
      iex> {:melee, melee} = List.keyfind(catalog, :melee, 0)
      iex> "FELDSPATEN" in melee and "M3 KNIFE" in melee
      true
  """
  @spec catalog() :: [{atom(), [String.t()]}]
  def catalog do
    grouped = @crcon_table |> Map.keys() |> Enum.group_by(&category/1)

    for category <- @categories, names = Map.get(grouped, category, []), names != [] do
      {category, Enum.sort_by(names, &String.downcase/1)}
    end
  end

  @doc """
  The category of a weapon, or `nil` without one.

      iex> alias HllConditionalActions.Games.Weapons
      iex> Weapons.category("M3 KNIFE")
      :melee
      iex> Weapons.category("FELDSPATEN")
      :melee
      iex> Weapons.category("MG42")
      :machine_gun
      iex> Weapons.category("75MM CANNON [Sd.Kfz.161 Panzer IV]")
      :armor
      iex> Weapons.category("Jeep Willys")
      :roadkill
      iex> Weapons.category("MACHETE")
      :melee
      iex> Weapons.category(nil)
      nil
  """
  @spec category(String.t() | nil) :: atom() | nil
  def category(nil), do: nil
  def category(""), do: nil

  def category(weapon) when is_binary(weapon) do
    upper = String.upcase(weapon)

    cond do
      Enum.any?(@melee, &String.contains?(upper, &1)) -> :melee
      String.contains?(upper, "FLAME") -> :flamethrower
      Enum.any?(@anti_tank, &String.contains?(upper, &1)) -> :anti_tank
      true -> from_table(weapon, upper)
    end
  end

  defp from_table(weapon, upper) do
    case Map.fetch(@crcon_table, weapon) do
      {:ok, :armor} -> if vehicle_gun?(upper), do: :armor, else: :roadkill
      {:ok, category} -> category
      :error -> guess(upper)
    end
  end

  # A tank's gun is named with its tank in brackets, or is a coaxial or hull
  # machine gun; a vehicle named on its own is the vehicle driving into you.
  defp vehicle_gun?(upper) do
    String.contains?(upper, "[") or String.starts_with?(upper, "COAXIAL") or
      String.starts_with?(upper, "HULL")
  end

  defp guess(upper) do
    cond do
      String.contains?(upper, ["BOMBING RUN", "STRAFING RUN", "PRECISION STRIKE"]) -> :commander
      String.contains?(upper, ["GRENADE", "MOLOTOV", "STIELHANDGRANATE"]) -> :grenade
      String.contains?(upper, ["MINE", "SATCHEL", "CLAYMORE", "C4"]) -> :explosive
      String.contains?(upper, ["HOWITZER", "MORTAR"]) -> :artillery
      vehicle_gun?(upper) -> :armor
      String.contains?(upper, ["SNIPER", "SCOPED", " X8", " X4"]) -> :sniper
      true -> :infantry
    end
  end
end
