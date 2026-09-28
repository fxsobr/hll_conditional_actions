defmodule HllConditionalActionsWeb.Labels do
  @moduledoc """
  Translated labels for the domain vocabulary.

  `HllConditionalActions.Rules.Catalog` and the accounts contexts speak in
  atoms; this module turns those atoms into text for the UI. The translations
  live here rather than next to the data so that every string is a literal
  `gettext/1` call that `mix gettext.extract` can find.
  """

  use Gettext, backend: HllConditionalActionsWeb.Gettext

  alias HllConditionalActions.Accounts.Permission
  alias HllConditionalActions.Crcon.PermissionNames
  alias HllConditionalActions.Rules.Catalog

  # ── Triggers ───────────────────────────────────────────────────────────────

  @doc """
  The label of a trigger event.
  """
  @spec trigger(atom()) :: String.t()
  def trigger(:player_connected), do: gettext("Player connects")
  def trigger(:player_disconnected), do: gettext("Player disconnects")
  def trigger(:player_kill), do: gettext("Player gets a kill")
  def trigger(:player_death), do: gettext("Player dies")
  def trigger(:player_team_kill), do: gettext("Player team kills")
  def trigger(:player_chat), do: gettext("Player writes in chat")
  def trigger(:chat_command), do: gettext("Player types a chat command")
  def trigger(:team_switch), do: gettext("Player switches team")
  def trigger(:vehicle_destroyed), do: gettext("Player destroys a vehicle")
  def trigger(:match_start), do: gettext("Match starts")
  def trigger(:match_end), do: gettext("Match ends")
  def trigger(:periodic), do: gettext("On a schedule")

  @doc """
  A one line explanation of what a trigger does.
  """
  @spec trigger_hint(atom()) :: String.t()
  def trigger_hint(:periodic),
    do: gettext("Checked every few seconds against every connected player.")

  def trigger_hint(trigger) when trigger in [:match_start, :match_end],
    do: gettext("Evaluated once for every connected player.")

  def trigger_hint(:chat_command),
    do:
      gettext(
        "Fires when a player writes a message starting with ! @ or #. The word after the prefix is the command."
      )

  def trigger_hint(:vehicle_destroyed),
    do:
      gettext(
        "HLL logs no line for this: the engine sees a player's destroyed vehicle count go up, within about ten seconds. It cannot tell whether the vehicle was manned, or where it stood."
      )

  def trigger_hint(_trigger), do: gettext("Evaluated for the player that caused the event.")

  @doc """
  Trigger options for a `<select>`.
  """
  @spec trigger_options() :: [{String.t(), String.t()}]
  def trigger_options do
    Enum.map(Catalog.triggers(), &{trigger(&1), to_string(&1)})
  end

  # ── Condition fields ───────────────────────────────────────────────────────

  @doc """
  The label of a condition field.
  """
  @spec field(atom()) :: String.t()
  def field(:always_true), do: gettext("Always")
  def field(:player_name), do: gettext("Player name")
  def field(:player_id), do: gettext("Player ID")
  def field(:player_level), do: gettext("Level")
  def field(:is_vip), do: gettext("Is VIP")
  def field(:player_role), do: gettext("Role")
  def field(:player_team), do: gettext("Team")
  def field(:player_unit_name), do: gettext("Squad")
  def field(:is_squad_leader), do: gettext("Is the squad leader")
  def field(:is_commander), do: gettext("Is the commander")
  def field(:squad_has_leader), do: gettext("Squad has a leader")
  def field(:squad_size), do: gettext("Squad size")
  def field(:squad_is_armor), do: gettext("Is in an armor squad")
  def field(:squad_is_solo_armor), do: gettext("Is alone in an armor squad")
  def field(:clan_tag), do: gettext("Clan tag (in-game field, not the name)")
  def field(:platform), do: gettext("Platform")
  def field(:kills), do: gettext("Kills")
  def field(:deaths), do: gettext("Deaths")
  def field(:kill_death_ratio), do: gettext("K/D ratio")
  def field(:teamkills), do: gettext("Team kills")
  def field(:combat_score), do: gettext("Combat score")
  def field(:offense_score), do: gettext("Offense score")
  def field(:defense_score), do: gettext("Defense score")
  def field(:support_score), do: gettext("Support score")
  def field(:kills_per_minute), do: gettext("Kills per minute")
  def field(:deaths_per_minute), do: gettext("Deaths per minute")
  def field(:playtime_seconds), do: gettext("Time on this map (seconds)")
  def field(:total_playtime_seconds), do: gettext("Total playtime (seconds)")
  def field(:sessions_count), do: gettext("Sessions played")
  def field(:penalty_count), do: gettext("Penalties received")
  def field(:flags), do: gettext("Flags")
  def field(:server_player_count), do: gettext("Players on the server")
  def field(:allied_player_count), do: gettext("Players on the allied team")
  def field(:axis_player_count), do: gettext("Players on the axis team")
  def field(:team_balance), do: gettext("Team difference (players)")
  def field(:allied_score), do: gettext("Allied score")
  def field(:vehicles_destroyed), do: gettext("Vehicles destroyed")
  def field(:team_objectives), do: gettext("Objectives held by their team")
  def field(:enemy_objectives), do: gettext("Objectives held by the enemy")
  def field(:attacking_last_sector), do: gettext("Their team attacks the enemy's last sector")
  def field(:defending_last_sector), do: gettext("Their team defends its own last sector")
  def field(:axis_score), do: gettext("Axis score")
  def field(:team_player_count), do: gettext("Players on the same team")
  def field(:queue_count), do: gettext("Players in queue")
  def field(:map_name), do: gettext("Map")
  def field(:game_mode), do: gettext("Game mode")
  def field(:match_time_remaining), do: gettext("Match time remaining (seconds)")
  def field(:hour_of_day), do: gettext("Hour of day (0-23)")
  def field(:day_of_week), do: gettext("Day of the week")
  def field(:message_content), do: gettext("Chat message")
  def field(:message_scope), do: gettext("Chat scope")
  def field(:message_team), do: gettext("Chat team")
  def field(:weapon), do: gettext("Weapon")
  def field(:target_player_name), do: gettext("Other player")
  def field(:event_action), do: gettext("Event type")
  def field(:strikes), do: gettext("Times this rule already hit this player")
  def field(:weapon_type), do: gettext("Weapon type")
  def field(:rank_kills), do: gettext("Position in kills")
  def field(:rank_kill_death_ratio), do: gettext("Position in K/D ratio")
  def field(:rank_kills_per_minute), do: gettext("Position in kills per minute")
  def field(:rank_combat), do: gettext("Position in combat score")
  def field(:rank_offense), do: gettext("Position in offense score")
  def field(:rank_defense), do: gettext("Position in defense score")
  def field(:rank_support), do: gettext("Position in support score")
  def field(:rank_vehicles_destroyed), do: gettext("Position in vehicles destroyed")
  def field(:rank_teamplay), do: gettext("Position in teamplay (combat + support)")
  def field(:rank_offdef), do: gettext("Position in offense + defense")
  def field(:squad_rank), do: gettext("Their squad's position among its type")
  def field(:squad_type), do: gettext("Their squad's type")
  def field(:command), do: gettext("Command")
  def field(:command_args), do: gettext("Command arguments")

  @doc """
  One line saying what a condition field reads, for the builder's field
  picker.
  """
  @spec field_description(atom()) :: String.t()
  def field_description(:always_true), do: gettext("No check: the actions run every time.")
  def field_description(:player_name), do: gettext("The player's in-game name.")
  def field_description(:player_id), do: gettext("The player's Steam or platform id.")
  def field_description(:player_level), do: gettext("The player's account level.")
  def field_description(:is_vip), do: gettext("Whether the player holds VIP on this server.")
  def field_description(:player_role), do: gettext("The role they play: rifleman, medic, tank...")
  def field_description(:player_team), do: gettext("The side they are on.")
  def field_description(:player_unit_name), do: gettext("The name of their squad.")
  def field_description(:is_squad_leader), do: gettext("Whether they lead their squad.")
  def field_description(:is_commander), do: gettext("Whether they are the team's commander.")
  def field_description(:squad_has_leader), do: gettext("Whether their squad has an officer.")
  def field_description(:squad_size), do: gettext("How many players are in their squad.")
  def field_description(:squad_is_armor), do: gettext("Whether their squad is a tank crew.")

  def field_description(:squad_is_solo_armor),
    do: gettext("Whether they drive a tank squad on their own.")

  def field_description(:clan_tag), do: gettext("The clan tag set in the game's profile.")
  def field_description(:platform), do: gettext("Steam, Epic, Xbox or PlayStation.")
  def field_description(:kills), do: gettext("Kills in the current match.")
  def field_description(:deaths), do: gettext("Deaths in the current match.")
  def field_description(:kill_death_ratio), do: gettext("Kills divided by deaths this match.")
  def field_description(:teamkills), do: gettext("Team kills in the current match.")
  def field_description(:combat_score), do: gettext("Combat score this match.")
  def field_description(:offense_score), do: gettext("Offense score this match.")
  def field_description(:defense_score), do: gettext("Defense score this match.")
  def field_description(:support_score), do: gettext("Support score this match.")
  def field_description(:kills_per_minute), do: gettext("Kills per minute on this map.")
  def field_description(:deaths_per_minute), do: gettext("Deaths per minute on this map.")
  def field_description(:playtime_seconds), do: gettext("Seconds played on the current map.")
  def field_description(:vehicles_destroyed), do: gettext("Vehicles destroyed this match.")
  def field_description(:rank_kills), do: gettext("1 means the most kills on the server.")
  def field_description(:rank_kill_death_ratio), do: gettext("1 means the best K/D ratio.")

  def field_description(:rank_kills_per_minute),
    do: gettext("1 means the most kills per minute.")

  def field_description(:rank_combat), do: gettext("1 means the best combat score.")
  def field_description(:rank_offense), do: gettext("1 means the best offense score.")
  def field_description(:rank_defense), do: gettext("1 means the best defense score.")
  def field_description(:rank_support), do: gettext("1 means the best support score.")

  def field_description(:rank_vehicles_destroyed),
    do: gettext("1 means the most vehicles destroyed.")

  def field_description(:rank_teamplay), do: gettext("1 means the best combat plus support.")
  def field_description(:rank_offdef), do: gettext("1 means the best offense plus defense.")

  def field_description(:squad_rank),
    do: gettext("Where their squad stands among squads of its type.")

  def field_description(:squad_type), do: gettext("Infantry, armor, recon or other.")

  def field_description(:total_playtime_seconds),
    do: gettext("Seconds played on this server, all time.")

  def field_description(:sessions_count), do: gettext("How many times they have connected.")
  def field_description(:penalty_count), do: gettext("Punishments, kicks and bans received.")
  def field_description(:flags), do: gettext("The flags CRCON admins put on the player.")
  def field_description(:server_player_count), do: gettext("Players connected right now.")
  def field_description(:allied_player_count), do: gettext("Players on the allied side.")
  def field_description(:axis_player_count), do: gettext("Players on the axis side.")

  def field_description(:team_balance),
    do: gettext("How many more players the bigger team has.")

  def field_description(:allied_score), do: gettext("Objectives the allies hold.")
  def field_description(:axis_score), do: gettext("Objectives the axis holds.")
  def field_description(:team_player_count), do: gettext("Players on the player's own team.")
  def field_description(:team_objectives), do: gettext("Objectives their team holds.")
  def field_description(:enemy_objectives), do: gettext("Objectives the enemy holds.")

  def field_description(:attacking_last_sector),
    do: gettext("Their team is one point from winning.")

  def field_description(:defending_last_sector),
    do: gettext("Their team is one point from losing.")

  def field_description(:queue_count), do: gettext("Players waiting to join.")
  def field_description(:map_name), do: gettext("The map being played.")
  def field_description(:game_mode), do: gettext("Warfare, offensive, skirmish...")
  def field_description(:match_time_remaining), do: gettext("Seconds left in the match.")
  def field_description(:hour_of_day), do: gettext("The hour in the server's time zone.")
  def field_description(:day_of_week), do: gettext("The day in the server's time zone.")
  def field_description(:message_content), do: gettext("What the player wrote.")
  def field_description(:message_scope), do: gettext("Team chat or all chat.")
  def field_description(:message_team), do: gettext("The side the message was written on.")
  def field_description(:weapon), do: gettext("The weapon of the kill.")
  def field_description(:weapon_type), do: gettext("The kind of weapon: rifle, melee, tank...")
  def field_description(:target_player_name), do: gettext("The other player of the kill.")
  def field_description(:event_action), do: gettext("The raw CRCON event type.")

  def field_description(:strikes),
    do: gettext("How often this rule already fired for the player.")

  def field_description(:command), do: gettext("The word after ! @ or #.")
  def field_description(:command_args), do: gettext("Whatever follows the command.")
  def field_description(_field), do: ""

  @doc """
  The label of a condition field group.
  """
  @spec field_group(atom()) :: String.t()
  def field_group(:general), do: gettext("General")
  def field_group(:player), do: gettext("Player")
  def field_group(:squad), do: gettext("Squad and role")
  def field_group(:match_stats), do: gettext("Match statistics")
  def field_group(:leaderboard), do: gettext("Leaderboard")
  def field_group(:profile), do: gettext("History")
  def field_group(:server), do: gettext("Server and match")
  def field_group(:schedule), do: gettext("Schedule")
  def field_group(:event), do: gettext("Event")

  @doc """
  Condition field options for a `<select>`, grouped and filtered by trigger.
  """
  @spec field_options(atom()) :: [{String.t(), [{String.t(), String.t()}]}]
  def field_options(trigger) do
    allowed = Catalog.fields_for_trigger(trigger)

    Catalog.field_groups()
    |> Enum.map(fn group ->
      fields =
        group
        |> Catalog.fields_in_group()
        |> Enum.filter(&(&1 in allowed))
        |> Enum.map(&{field(&1), to_string(&1)})

      {field_group(group), fields}
    end)
    |> Enum.reject(fn {_group, fields} -> fields == [] end)
  end

  # ── Operators ──────────────────────────────────────────────────────────────

  @doc """
  The label of a comparison operator.
  """
  @spec operator(atom()) :: String.t()
  def operator(:equal), do: gettext("is")
  def operator(:not_equal), do: gettext("is not")
  def operator(:greater_than), do: gettext("is greater than")
  def operator(:greater_than_or_equal), do: gettext("is at least")
  def operator(:less_than), do: gettext("is less than")
  def operator(:less_than_or_equal), do: gettext("is at most")
  def operator(:contains), do: gettext("contains")
  def operator(:not_contains), do: gettext("does not contain")
  def operator(:starts_with), do: gettext("starts with")
  def operator(:ends_with), do: gettext("ends with")
  def operator(:regex_match), do: gettext("matches the pattern")
  def operator(:in_list), do: gettext("is one of")
  def operator(:not_in_list), do: gettext("is none of")

  @doc """
  The label of a weekday.
  """
  @spec day_of_week(String.t()) :: String.t()
  def day_of_week("monday"), do: gettext("Monday")
  def day_of_week("tuesday"), do: gettext("Tuesday")
  def day_of_week("wednesday"), do: gettext("Wednesday")
  def day_of_week("thursday"), do: gettext("Thursday")
  def day_of_week("friday"), do: gettext("Friday")
  def day_of_week("saturday"), do: gettext("Saturday")
  def day_of_week("sunday"), do: gettext("Sunday")
  def day_of_week(day), do: day

  @doc """
  The allowed values of a condition field, with translated labels.

  Wraps `HllConditionalActions.Rules.Catalog.field_options/2`, which returns
  raw values; weekday names are the one set that needs translating (roles,
  teams and map names come from the game itself).
  """
  @spec value_options(atom(), atom()) :: [{String.t(), String.t()}] | nil
  def value_options(field, game) do
    case Catalog.field_options(field, game) do
      nil ->
        nil

      options when field == :day_of_week ->
        Enum.map(options, fn {_, v} -> {day_of_week(v), v} end)

      options when field == :weapon_type ->
        Enum.map(options, fn {_, v} -> {weapon_type(String.to_existing_atom(v)), v} end)

      options when field == :squad_type ->
        Enum.map(options, fn {_, v} -> {squad_type(String.to_existing_atom(v)), v} end)

      options ->
        options
    end
  end

  @doc "The label of an achievement or season metric."
  @spec metric(atom()) :: String.t()
  def metric(:kills), do: gettext("Kills")
  def metric(:combat), do: gettext("Combat score")
  def metric(:offense), do: gettext("Offense score")
  def metric(:defense), do: gettext("Defense score")
  def metric(:support), do: gettext("Support score")
  def metric(:teamplay), do: gettext("Teamplay (combat + support)")
  def metric(:vehicles_destroyed), do: gettext("Vehicles destroyed")
  def metric(:playtime_minutes), do: gettext("Minutes played")
  def metric(:matches), do: gettext("Matches played")
  def metric(:commander_matches), do: gettext("Matches as commander")
  def metric(:leader_matches), do: gettext("Matches leading a squad")

  @doc "Metric options for a `<select>`."
  @spec metric_options([atom()]) :: [{String.t(), String.t()}]
  def metric_options(metrics), do: Enum.map(metrics, &{metric(&1), to_string(&1)})

  @doc "The name of a way to rank a season."
  @spec scoring(atom()) :: String.t()
  def scoring(:sum), do: gettext("Total of one stat")
  def scoring(:average), do: gettext("Average per match")
  def scoring(:weighted), do: gettext("Combined score")
  def scoring(:elo), do: gettext("Elo rating")

  @doc "What a way to rank a season rewards, in one line."
  @spec scoring_hint(atom()) :: String.t()
  def scoring_hint(:sum),
    do: gettext("Adds one stat up, match after match. Rewards whoever plays the most.")

  def scoring_hint(:average),
    do:
      gettext("The stat divided by the matches played. Rewards playing well, not playing a lot.")

  def scoring_hint(:weighted),
    do: gettext("Each stat times the weight you give it. Say what your server values.")

  def scoring_hint(:elo),
    do:
      gettext(
        "Everybody starts at 1000. Winning against a stronger team earns more, and your own teamplay scales what you win or lose."
      )

  @doc "What a season's standings column counts."
  @spec season_measure(map()) :: String.t()
  def season_measure(%{scoring: :elo}), do: gettext("Rating")
  def season_measure(%{scoring: :weighted}), do: gettext("Points")

  def season_measure(%{scoring: :average, metric: metric}),
    do: gettext("%{metric} per match", metric: metric(metric))

  def season_measure(%{metric: metric}) when not is_nil(metric), do: metric(metric)
  def season_measure(_season), do: gettext("Points")

  @doc "The label of an achievement tier."
  @spec tier(atom()) :: String.t()
  def tier(:bronze), do: gettext("Bronze")
  def tier(:silver), do: gettext("Silver")
  def tier(:gold), do: gettext("Gold")
  def tier(:legendary), do: gettext("Legendary")

  @doc "The label of an achievement scope."
  @spec achievement_scope(atom()) :: String.t()
  def achievement_scope(:match), do: gettext("In one match")
  def achievement_scope(:career), do: gettext("Over a career on the server")

  @doc """
  What an achievement asks for, in one line: "40 kills in one match".
  """
  @spec achievement_goal(map()) :: String.t()
  def achievement_goal(%{scope: :match} = achievement),
    do:
      gettext("%{threshold} · %{metric}, in one match",
        threshold: achievement.threshold,
        metric: metric(achievement.metric)
      )

  def achievement_goal(achievement),
    do:
      gettext("%{threshold} · %{metric}, over a career",
        threshold: achievement.threshold,
        metric: metric(achievement.metric)
      )

  @doc "The label of a weapon category."
  @spec weapon_type(atom()) :: String.t()
  def weapon_type(:melee), do: gettext("Melee (knife, spade)")
  def weapon_type(:infantry), do: gettext("Infantry weapon")
  def weapon_type(:machine_gun), do: gettext("Machine gun")
  def weapon_type(:sniper), do: gettext("Sniper rifle")
  def weapon_type(:grenade), do: gettext("Grenade")
  def weapon_type(:explosive), do: gettext("Mine or satchel")
  def weapon_type(:anti_tank), do: gettext("Anti-tank launcher or rifle")
  def weapon_type(:flamethrower), do: gettext("Flamethrower")
  def weapon_type(:at_gun), do: gettext("Anti-tank gun")
  def weapon_type(:artillery), do: gettext("Artillery")
  def weapon_type(:armor), do: gettext("Tank or vehicle gun")
  def weapon_type(:roadkill), do: gettext("Run over by a vehicle")
  def weapon_type(:commander), do: gettext("Commander ability")

  @doc """
  The label of a squad type.
  """
  @spec squad_type(atom()) :: String.t()
  def squad_type(:infantry), do: gettext("Infantry")
  def squad_type(:armor), do: gettext("Armor")
  def squad_type(:recon), do: gettext("Recon")
  def squad_type(:artillery), do: gettext("Artillery")

  @doc """
  The label of a leaderboard category.
  """
  @spec leaderboard_category(atom()) :: String.t()
  def leaderboard_category(:kills), do: gettext("Kills")
  def leaderboard_category(:kill_death_ratio), do: gettext("K/D ratio")
  def leaderboard_category(:kills_per_minute), do: gettext("Kills per minute")
  def leaderboard_category(:combat), do: gettext("Combat")
  def leaderboard_category(:offense), do: gettext("Offense")
  def leaderboard_category(:defense), do: gettext("Defense")
  def leaderboard_category(:support), do: gettext("Support")
  def leaderboard_category(:vehicles_destroyed), do: gettext("Vehicles destroyed")
  def leaderboard_category(:teamplay), do: gettext("Teamplay")
  def leaderboard_category(:offdef), do: gettext("Offense + defense")

  @doc """
  Operator options valid for a field.
  """
  @spec operator_options(atom()) :: [{String.t(), String.t()}]
  def operator_options(field) do
    field
    |> Catalog.operators_for_field()
    |> Enum.map(&{operator(&1), to_string(&1)})
  end

  @doc """
  The label of a logical operator.
  """
  @spec logical_operator(atom()) :: String.t()
  def logical_operator(:and), do: gettext("All conditions must hold")
  def logical_operator(:or), do: gettext("Any condition may hold")
  def logical_operator(:nand), do: gettext("Not all conditions hold")
  def logical_operator(:nor), do: gettext("No condition holds")

  @doc """
  Logical operator options for a `<select>`.
  """
  @spec logical_operator_options() :: [{String.t(), String.t()}]
  def logical_operator_options do
    Enum.map(Catalog.logical_operators(), &{logical_operator(&1), to_string(&1)})
  end

  @doc """
  A one or two word form of a logical operator, for the segmented control in
  the rule builder where the full sentence does not fit.
  """
  @spec logical_operator_short(atom()) :: String.t()
  def logical_operator_short(:and), do: gettext("All")
  def logical_operator_short(:or), do: gettext("Any")
  def logical_operator_short(:nand), do: gettext("Not all")
  def logical_operator_short(:nor), do: gettext("None")

  @doc """
  The word placed between two conditions when reading a rule out loud.

  `:nand` and `:nor` negate the whole clause rather than the join, so they
  read as "and" and "or" between the individual conditions.
  """
  @spec logical_joiner(atom()) :: String.t()
  def logical_joiner(operator) when operator in [:or, :nor], do: gettext("or")
  def logical_joiner(_operator), do: gettext("and")

  @doc """
  Yes/no options for a `<select>` over a boolean condition field.
  """
  @spec boolean_options() :: [{String.t(), String.t()}]
  def boolean_options do
    [{gettext("Yes"), "true"}, {gettext("No"), "false"}]
  end

  # ── Actions ────────────────────────────────────────────────────────────────

  @doc """
  The label of an action type.
  """
  @spec action(atom()) :: String.t()
  def action(:message_player), do: gettext("Message the player")
  def action(:message_all_players), do: gettext("Message every player")
  def action(:broadcast_message), do: gettext("Set the broadcast")
  def action(:temporary_broadcast), do: gettext("Broadcast temporarily")
  def action(:set_welcome_message), do: gettext("Set the welcome screen")
  def action(:punish_player), do: gettext("Punish the player")
  def action(:kick_player), do: gettext("Kick the player")
  def action(:temp_ban_player), do: gettext("Temporarily ban the player")
  def action(:perma_ban_player), do: gettext("Permanently ban the player")
  def action(:switch_player_team), do: gettext("Switch the player's team now")
  def action(:switch_player_on_death), do: gettext("Switch the player's team on death")
  def action(:add_player_flag), do: gettext("Add a flag")
  def action(:remove_player_flag), do: gettext("Remove a flag")
  def action(:add_to_watchlist), do: gettext("Add to the watchlist")
  def action(:remove_from_watchlist), do: gettext("Remove from the watchlist")
  def action(:open_ticket), do: gettext("Open a ticket for the admins")
  def action(:grant_vip), do: gettext("Grant VIP")
  def action(:remove_vip), do: gettext("Remove VIP")
  def action(:blacklist_player), do: gettext("Add to a blacklist")
  def action(:send_discord_webhook), do: gettext("Send a Discord message")

  @doc """
  Action options for a `<select>`.
  """
  @spec action_options() :: [{String.t(), String.t()}]
  def action_options do
    Catalog.action_groups()
    |> Enum.map(fn group ->
      {action_group(group),
       group |> Catalog.actions_in_group() |> Enum.map(&{action(&1), to_string(&1)})}
    end)
    |> Enum.reject(fn {_group, actions} -> actions == [] end)
  end

  @doc """
  What a rule health issue means, in one line.
  """
  @spec health_issue(atom()) :: String.t()
  def health_issue(:missing_permission), do: gettext("This will never work")
  def health_issue(:always_failing), do: gettext("Every run is failing")
  def health_issue(:never_fired), do: gettext("Never fired")
  def health_issue(:quiet), do: gettext("Quiet for a month")

  @doc """
  Why the issue matters and what to do about it.
  """
  @spec health_explanation(atom()) :: String.t()
  def health_explanation(:missing_permission),
    do:
      gettext(
        "The CRCON key on this server is not allowed to do what this rule asks. Grant the permission in CRCON, then test the connection again."
      )

  def health_explanation(:always_failing),
    do:
      gettext(
        "This rule fires but every action comes back with an error. Open the history to see what CRCON answered."
      )

  def health_explanation(:never_fired),
    do:
      gettext(
        "This rule has been enabled for a while and has never matched anything. Usually one condition is stricter than intended."
      )

  def health_explanation(:quiet),
    do:
      gettext(
        "This rule used to fire and has not in the last month. That may be fine, or something it depended on may have changed."
      )

  @doc """
  The name of a recipe, and the one line that sells it.
  """
  @spec recipe_name(atom()) :: String.t()
  def recipe_name(:welcome), do: gettext("Welcome message")
  def recipe_name(:no_squad_leader), do: gettext("Squad without an officer")
  def recipe_name(:solo_tank), do: gettext("Solo tanker")
  def recipe_name(:team_kill_ladder), do: gettext("Team killing, escalating")
  def recipe_name(:seeding_reward), do: gettext("Reward the people who seed")
  def recipe_name(:chat_command_discord), do: gettext("Answer !discord in chat")
  def recipe_name(:new_player_watch), do: gettext("Keep an eye on brand new players")
  def recipe_name(:top_command), do: gettext("Answer !top with the live leaderboard")
  def recipe_name(:match_end_leaderboard), do: gettext("Show the top players at match end")
  def recipe_name(:top_support_vip), do: gettext("VIP for the best supporter")
  def recipe_name(:melee_kill), do: gettext("Praise melee kills")
  def recipe_name(:mvp_vip), do: gettext("VIP for the match MVP")
  def recipe_name(:best_squad_vip), do: gettext("VIP for the best squad")
  def recipe_name(:commander_reward), do: gettext("Thank the commander")
  def recipe_name(:squad_leader_reward), do: gettext("Thank the squad leaders")
  def recipe_name(:achievements_command), do: gettext("Answer !achievements")
  def recipe_name(:season_command), do: gettext("Answer !season")

  @spec recipe_description(atom()) :: String.t()
  def recipe_description(:welcome),
    do: gettext("Greets every player by name as they connect.")

  def recipe_description(:no_squad_leader),
    do:
      gettext(
        "Warns a squad with no officer twice, then punishes. Only on a busy server, and only for squads of three or more."
      )

  def recipe_description(:solo_tank),
    do: gettext("Asks a lone tanker to crew up or switch role, then punishes.")

  def recipe_description(:team_kill_ladder),
    do:
      gettext("Warn, punish, kick, then a two hour ban — one step per team kill within the hour.")

  def recipe_description(:seeding_reward),
    do: gettext("Gives 24 hours of VIP to anyone who plays 30 minutes on a near empty server.")

  def recipe_description(:chat_command_discord),
    do: gettext("Replies with your invite when a player types !discord.")

  def recipe_description(:new_player_watch),
    do: gettext("Welcomes players below level 10 and adds them to the watchlist.")

  def recipe_description(:top_command),
    do:
      gettext(
        "A player types !top and privately gets the live top three in kills, teamplay and offense + defense, plus the best squads."
      )

  def recipe_description(:mvp_vip),
    do:
      gettext(
        "The best in teamplay (combat + support) of a full match gets VIP for 24 hours, once a day at most."
      )

  def recipe_description(:best_squad_vip),
    do:
      gettext(
        "Every member of the best infantry squad of the match gets VIP for 12 hours, once a day at most."
      )

  def recipe_description(:commander_reward),
    do:
      gettext(
        "Whoever commanded at least 40 minutes of a full match gets VIP for 24 hours and a thank you."
      )

  def recipe_description(:squad_leader_reward),
    do:
      gettext(
        "Squad leaders of a squad of 4 or more, for at least 40 minutes of a full match, get VIP for 12 hours."
      )

  def recipe_description(:achievements_command),
    do: gettext("A player types !achievements and privately gets the list they unlocked.")

  def recipe_description(:season_command),
    do:
      gettext("A player types !season and privately gets their position and the season's top 5.")

  def recipe_description(:melee_kill),
    do:
      gettext(
        "Whoever kills with a knife or a spade gets a private message naming their victim and the weapon."
      )

  def recipe_description(:match_end_leaderboard),
    do: gettext("When the match ends, everybody sees who topped kills, support and defense.")

  def recipe_description(:top_support_vip),
    do:
      gettext(
        "The number one in support score, with at least 30 minutes played on a full server, gets VIP for 24 hours."
      )

  @doc """
  What happened to a rule, for its change history.
  """
  @spec version_action(atom()) :: String.t()
  def version_action(:created), do: gettext("created")
  def version_action(:updated), do: gettext("edited")
  def version_action(:enabled), do: gettext("enabled")
  def version_action(:disabled), do: gettext("disabled")
  def version_action(:duplicated), do: gettext("duplicated")
  def version_action(:deleted), do: gettext("removed")
  def version_action(:imported), do: gettext("imported")
  def version_action(:paused), do: gettext("paused")
  def version_action(:resumed), do: gettext("resumed")
  def version_action(action), do: to_string(action)

  @doc """
  The name of a rule field as it reads in the change history.
  """
  @spec rule_field(String.t()) :: String.t()
  def rule_field("name"), do: gettext("Name")
  def rule_field("description"), do: gettext("Description")
  def rule_field("enabled"), do: gettext("Enabled")
  def rule_field("simulation"), do: gettext("Simulation only")
  def rule_field("priority"), do: gettext("Priority")
  def rule_field("group"), do: gettext("Group")
  def rule_field("game"), do: gettext("Game")
  def rule_field("server_id"), do: gettext("Applies to")
  def rule_field("trigger_event"), do: gettext("Trigger")
  def rule_field("trigger_interval_seconds"), do: gettext("Every (seconds)")
  def rule_field("logical_operator"), do: gettext("How conditions combine")
  def rule_field("cooldown_seconds"), do: gettext("Cooldown per player (seconds)")
  def rule_field("max_executions_per_player"), do: gettext("Maximum times per player per day")
  def rule_field("escalation_window_seconds"), do: gettext("Escalate repeat offenders (seconds)")
  def rule_field("paused_until"), do: gettext("Paused until")
  def rule_field("pause_reason"), do: gettext("Pause reason")
  def rule_field("conditions"), do: gettext("Conditions")
  def rule_field("actions"), do: gettext("Actions")
  def rule_field(field), do: field

  @doc """
  The label of an action group.
  """
  @spec action_group(atom()) :: String.t()
  def action_group(:messaging), do: gettext("Talk to players")
  def action_group(:punishment), do: gettext("Punish")
  def action_group(:team), do: gettext("Move between teams")
  def action_group(:marking), do: gettext("Mark and reward")
  def action_group(:integrations), do: gettext("Elsewhere")

  @doc """
  The label of an action parameter.
  """
  @spec action_param(atom()) :: String.t()
  def action_param(:message), do: gettext("Message")
  def action_param(:reason), do: gettext("Reason")
  def action_param(:duration_hours), do: gettext("Duration (hours)")
  def action_param(:duration_seconds), do: gettext("Duration (seconds)")
  def action_param(:flag), do: gettext("Flag")
  def action_param(:comment), do: gettext("Comment")
  def action_param(:webhook_id), do: gettext("Webhook")
  def action_param(:embed_title), do: gettext("Title")
  def action_param(:embed_description), do: gettext("Description")
  def action_param(:embed_fields), do: gettext("Fields")
  def action_param(:embed_footer), do: gettext("Footer")
  def action_param(:embed_color), do: gettext("Colour")
  def action_param(:embed_thumbnail_url), do: gettext("Thumbnail image URL")
  def action_param(:embed_timestamp), do: gettext("Show the time")
  def action_param(:username), do: gettext("Sender name")
  def action_param(:avatar_url), do: gettext("Sender avatar URL")
  def action_param(:mention_role_ids), do: gettext("Roles it may mention")
  def action_param(:silent), do: gettext("Silent (no notification)")
  def action_param(:mode), do: gettext("Each time it fires")
  def action_param(:edit_key), do: gettext("One message per")
  def action_param(:thread_id), do: gettext("Thread id")
  def action_param(:thread_name), do: gettext("Forum post title")
  def action_param(:aggregate), do: gettext("One message for all the players of the sweep")

  def action_param(:description), do: gettext("Description")
  def action_param(:blacklist_id), do: gettext("Blacklist number in CRCON")
  def action_param(:note), do: gettext("Note for the admins")
  def action_param(:priority), do: gettext("Priority")

  @doc """
  The choices of an action's select parameter.
  """
  @spec action_param_options(atom()) :: [{String.t(), String.t()}]
  def action_param_options(:priority), do: ticket_priority_options()

  def action_param_options(:mode), do: discord_mode_options()

  @doc """
  The choices of the Discord action's "each time it fires" setting.
  """
  @spec discord_mode_options() :: [{String.t(), String.t()}]
  def discord_mode_options do
    [
      {gettext("Post a new message"), "send"},
      {gettext("Edit the same message"), "edit"}
    ]
  end

  # ── Games ──────────────────────────────────────────────────────────────────

  @doc """
  The label of a game.
  """
  @spec game(atom() | String.t()) :: String.t()
  def game(:hll), do: gettext("Hell Let Loose")
  def game(:hllv), do: gettext("Hell Let Loose: Vietnam")
  def game(game) when is_binary(game), do: game |> String.to_existing_atom() |> game()

  @doc """
  Game options for a `<select>`.
  """
  @spec game_options() :: [{String.t(), String.t()}]
  def game_options do
    Enum.map(HllConditionalActions.Games.all(), &{game(&1), to_string(&1)})
  end

  # ── CRCON permissions ──────────────────────────────────────────────────────

  @doc """
  The name CRCON itself gives a permission, as its Django admin lists it.

  Taken from CRCON's own permission list (see
  `HllConditionalActions.Crcon.PermissionNames`) so the operator can match
  what they read here against the admin, where each checkbox reads
  `api | rcon user | <name>`. Not run through gettext for the same reason:
  CRCON's admin is English only.

      iex> HllConditionalActionsWeb.Labels.crcon_permission("can_view_structured_logs")
      "Can view the get_structured_logs endpoint"
      iex> HllConditionalActionsWeb.Labels.crcon_permission("auth.add_user")
      "auth.add_user"
  """
  @spec crcon_permission(String.t()) :: String.t()
  def crcon_permission(permission),
    do: PermissionNames.name(permission) || permission

  @doc """
  A permission exactly as CRCON's Django admin prints it.

      iex> HllConditionalActionsWeb.Labels.crcon_admin_permission("can_kick_players")
      "api | rcon user | Can kick players"
      iex> HllConditionalActionsWeb.Labels.crcon_admin_permission("auth.add_user")
      "auth.add_user"
  """
  @spec crcon_admin_permission(String.t()) :: String.t()
  def crcon_admin_permission(permission) do
    case PermissionNames.name(permission) do
      nil -> permission
      name -> "api | rcon user | " <> name
    end
  end

  @doc """
  What stops working when a key lacks one of the engine's read permissions.

  CRCON answers 403 to a read it does not allow, and the engine can only log
  it - so this is where that silence gets a sentence.
  """
  @spec crcon_read_impact(String.t()) :: String.t()
  def crcon_read_impact("can_view_detailed_players"),
    do:
      gettext(
        "every condition about a player - level, VIP, squad, score, playtime - stops matching"
      )

  def crcon_read_impact("can_view_gamestate"),
    do:
      gettext(
        "conditions about the match - map, mode, score, players online, time left - stop matching"
      )

  def crcon_read_impact("can_view_player_profile"),
    do:
      gettext(
        "conditions about a player's history - sessions, penalties, total playtime - stop matching"
      )

  def crcon_read_impact("can_view_broadcast_message"),
    do: gettext("a temporary broadcast cannot put the previous message back")

  def crcon_read_impact("can_view_get_status"),
    do: gettext("the server page cannot show the live map and player count")

  def crcon_read_impact(_permission), do: gettext("part of what the engine reads will fail")

  @doc """
  A permission as the admin shows it, with its codename, on a single line.

      iex> HllConditionalActionsWeb.Labels.crcon_permission_with_code("can_kick_players")
      "api | rcon user | Can kick players (can_kick_players)"
  """
  @spec crcon_permission_with_code(String.t()) :: String.t()
  def crcon_permission_with_code(permission) do
    case PermissionNames.name(permission) do
      nil -> permission
      _name -> "#{crcon_admin_permission(permission)} (#{permission})"
    end
  end

  # ── Permissions ────────────────────────────────────────────────────────────

  @doc """
  The label of a permission.
  """
  @spec permission(atom()) :: String.t()
  def permission(:view_servers), do: gettext("View servers")
  def permission(:manage_servers), do: gettext("Add, edit and remove servers")
  def permission(:view_rules), do: gettext("View rules")
  def permission(:manage_rules), do: gettext("Create, edit and remove rules")
  def permission(:view_executions), do: gettext("View the rule history")
  def permission(:view_live_feed), do: gettext("Watch the live event feed")
  def permission(:view_stats), do: gettext("See matches, players and leaderboards")
  def permission(:view_progression), do: gettext("See seasons and achievements")
  def permission(:manage_progression), do: gettext("Run seasons and edit achievements")
  def permission(:manage_integrations), do: gettext("Manage Discord integrations")
  def permission(:view_tickets), do: gettext("See player tickets")
  def permission(:manage_tickets), do: gettext("Answer and close player tickets")
  def permission(:manage_users), do: gettext("Manage users")
  def permission(:manage_roles), do: gettext("Manage roles and permissions")

  @doc """
  The label of a permission group.
  """
  @spec permission_group(atom()) :: String.t()
  def permission_group(:servers), do: gettext("Servers")
  def permission_group(:rules), do: gettext("Rules")
  def permission_group(:monitoring), do: gettext("Monitoring")
  def permission_group(:community), do: gettext("Community")
  def permission_group(:support), do: gettext("Support")
  def permission_group(:platform), do: gettext("Platform")

  @doc """
  The name of a marketplace module.
  """
  @spec feature(atom()) :: String.t()
  def feature(:rules), do: gettext("Conditional rules")
  def feature(:tickets), do: gettext("Tickets")
  def feature(:progression), do: gettext("Achievements and seasons")
  def feature(:stats), do: gettext("Leaderboard and matches")
  def feature(:live_feed), do: gettext("Live feed")

  @doc """
  What a marketplace module adds, for its card.
  """
  @spec feature_description(atom()) :: String.t()
  def feature_description(:rules),
    do:
      gettext(
        "Automate the server: conditions on the game trigger messages, kicks, bans and more. Includes history."
      )

  def feature_description(:tickets),
    do: gettext("Players open support tickets from the in-game chat and admins answer them here.")

  def feature_description(:progression),
    do: gettext("Reward players with achievements and run ranked seasons across matches.")

  def feature_description(:stats),
    do: gettext("Live leaderboard of players and squads, plus the history of every match.")

  def feature_description(:live_feed),
    do: gettext("Watch kills, chat and connections as they happen on the server.")

  @doc """
  Permissions grouped for the role form.
  """
  @spec permission_groups() :: [{String.t(), [{atom(), String.t()}]}]
  def permission_groups do
    Enum.map(Permission.groups(), fn group ->
      {permission_group(group), group |> Permission.in_group() |> Enum.map(&{&1, permission(&1)})}
    end)
  end

  # ── Statuses ───────────────────────────────────────────────────────────────

  @doc """
  The label of an execution status.
  """
  @spec execution_status(atom() | String.t()) :: String.t()
  def execution_status(:executed), do: gettext("Executed")
  def execution_status(:partial), do: gettext("Partially executed")
  def execution_status(:failed), do: gettext("Failed")
  def execution_status(:simulated), do: gettext("Simulated")
  def execution_status(status) when is_binary(status), do: status

  @doc """
  The label of a ticket status.
  """
  @spec ticket_status(atom()) :: String.t()
  def ticket_status(:open), do: gettext("Waiting for an admin")
  def ticket_status(:answered), do: gettext("Answered")
  def ticket_status(:closed), do: gettext("Closed")

  @doc "The label of a ticket priority."
  @spec ticket_priority(atom()) :: String.t()
  def ticket_priority(:low), do: gettext("Low")
  def ticket_priority(:normal), do: gettext("Normal")
  def ticket_priority(:high), do: gettext("High")
  def ticket_priority(:urgent), do: gettext("Urgent")

  @doc "The tone a ticket priority is shown in."
  @spec ticket_priority_tone(atom()) :: String.t()
  def ticket_priority_tone(:urgent), do: "error"
  def ticket_priority_tone(:high), do: "warning"
  def ticket_priority_tone(_priority), do: "neutral"

  @doc "Ticket priorities for a `<select>`, lowest first."
  @spec ticket_priority_options() :: [{String.t(), String.t()}]
  def ticket_priority_options do
    Enum.map(
      HllConditionalActions.Tickets.Ticket.priorities(),
      &{ticket_priority(&1), to_string(&1)}
    )
  end

  @doc "Why a ticket was closed."
  @spec close_reason(String.t() | nil) :: String.t()
  def close_reason("resolved"), do: gettext("Resolved")
  def close_reason("duplicate"), do: gettext("Duplicate")
  def close_reason("no_action"), do: gettext("No action needed")
  def close_reason("player_left"), do: gettext("Player left")
  def close_reason("inactivity"), do: gettext("Closed for inactivity")
  def close_reason("player"), do: gettext("Closed by the player")
  def close_reason("other"), do: gettext("Other")
  def close_reason(reason) when is_binary(reason), do: reason
  def close_reason(nil), do: "–"

  @doc "The tone a ticket status is shown in."
  @spec ticket_status_tone(atom()) :: String.t()
  def ticket_status_tone(:open), do: "warning"
  def ticket_status_tone(:answered), do: "info"
  def ticket_status_tone(:closed), do: "neutral"

  @doc """
  The label of a log stream status.
  """
  @spec stream_status(term()) :: String.t()
  def stream_status(:connected), do: gettext("Live")
  def stream_status(:connecting), do: gettext("Connecting")
  def stream_status(:disconnected), do: gettext("Offline")
  def stream_status({:error, _reason}), do: gettext("Error")
  def stream_status(_status), do: gettext("Unknown")

  @doc """
  The label of a CRCON event type, for the live feed.
  """
  @spec event_type(atom()) :: String.t()
  def event_type(:player_connected), do: gettext("Connected")
  def event_type(:player_disconnected), do: gettext("Disconnected")
  def event_type(:player_kill), do: gettext("Kill")
  def event_type(:player_team_kill), do: gettext("Team kill")
  def event_type(:player_chat), do: gettext("Chat")
  def event_type(:team_switch), do: gettext("Team switch")
  def event_type(:match_start), do: gettext("Match start")
  def event_type(:match_end), do: gettext("Match end")
  def event_type(:admin_action), do: gettext("Admin action")
  def event_type(:camera), do: gettext("Camera")
  def event_type(:vote), do: gettext("Vote")
  def event_type(_type), do: gettext("Other")
end
