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
  def field(:command), do: gettext("Command")
  def field(:command_args), do: gettext("Command arguments")

  @doc """
  The label of a condition field group.
  """
  @spec field_group(atom()) :: String.t()
  def field_group(:general), do: gettext("General")
  def field_group(:player), do: gettext("Player")
  def field_group(:squad), do: gettext("Squad and role")
  def field_group(:match_stats), do: gettext("Match statistics")
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

      options ->
        options
    end
  end

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
  def action_param(:webhook_url), do: gettext("Webhook URL")
  def action_param(:description), do: gettext("Description")
  def action_param(:blacklist_id), do: gettext("Blacklist number in CRCON")

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
  The description CRCON itself gives a permission.

  Copied verbatim from CRCON's `RconUser` permission list
  (`rconweb/api/migrations/0024_alter_rconuser_options.py`), which is what the
  Django admin displays next to each checkbox. Using its exact wording rather
  than our own means the operator can match what they read here against what
  they see there, without translating twice.

  Not run through gettext for the same reason: CRCON's admin is English only.
  """
  @spec crcon_permission(String.t()) :: String.t()
  def crcon_permission("can_view_structured_logs"),
    do: "Can view the get_structured_logs endpoint"

  def crcon_permission("can_view_detailed_players"),
    do: "Can view get_detailed_players endpoint"

  def crcon_permission("can_view_gamestate"), do: "Can view the current gamestate"
  def crcon_permission("can_view_player_profile"), do: "View the detailed player profile page"
  def crcon_permission("can_view_broadcast_message"), do: "Can view the current broadcast message"

  def crcon_permission("can_view_get_status"),
    do: "Can view the get_status endpoint (server name, current map, player count)"

  def crcon_permission("can_message_players"), do: "Can message players"
  def crcon_permission("can_punish_players"), do: "Can punish players"
  def crcon_permission("can_kick_players"), do: "Can kick players"
  def crcon_permission("can_temp_ban_players"), do: "Can temporarily ban players"
  def crcon_permission("can_perma_ban_players"), do: "Can permanently ban players"
  def crcon_permission("can_switch_players_immediately"), do: "Can immediately switch players"
  def crcon_permission("can_switch_players_on_death"), do: "Can switch players on death"
  def crcon_permission("can_flag_player"), do: "Can add flags to players"
  def crcon_permission("can_unflag_player"), do: "Can remove flags from players"
  def crcon_permission("can_add_player_watch"), do: "Can add a watch to players"
  def crcon_permission("can_remove_player_watch"), do: "Can remove a watch from players"
  def crcon_permission("can_change_broadcast_message"), do: "Can change the broadcast message"
  def crcon_permission("can_change_welcome_message"), do: "Can change the welcome (rules) message"
  def crcon_permission("can_add_vip"), do: "Can add VIP status to players"
  def crcon_permission("can_remove_vip"), do: "Can remove VIP status from players"
  def crcon_permission("can_add_blacklist_records"), do: "Can add players to blacklists"
  # Anything outside the catalog is a permission this app never asks for, so
  # the codename is the most honest thing to show.
  def crcon_permission(permission), do: permission

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
  A permission with its codename, for listing one on a single line.

      iex> HllConditionalActionsWeb.Labels.crcon_permission_with_code("can_kick_players")
      "Can kick players (can_kick_players)"
  """
  @spec crcon_permission_with_code(String.t()) :: String.t()
  def crcon_permission_with_code(permission) do
    "#{crcon_permission(permission)} (#{permission})"
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
  def permission(:manage_users), do: gettext("Manage users")
  def permission(:manage_roles), do: gettext("Manage roles and permissions")

  @doc """
  The label of a permission group.
  """
  @spec permission_group(atom()) :: String.t()
  def permission_group(:servers), do: gettext("Servers")
  def permission_group(:rules), do: gettext("Rules")
  def permission_group(:monitoring), do: gettext("Monitoring")
  def permission_group(:platform), do: gettext("Platform")

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
