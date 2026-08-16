defmodule HllConditionalActions.Engine.Context do
  @moduledoc """
  Everything a rule is evaluated against for one player, at one moment.

  The engine fetches CRCON's expensive endpoints (`get_detailed_players`,
  `get_gamestate`) once per evaluation cycle and shares the result across every
  rule and player, mirroring how CRCON's own processor caches them. A context
  is therefore cheap to build once that snapshot exists.

  The player profile (`get_player_profile`) is a separate, per-player call, so
  it is only fetched when a rule actually reads a `:profile` field - see
  `needs_player_profile?/1`.
  """

  alias HllConditionalActions.Crcon.Events.Event
  alias HllConditionalActions.Games
  alias HllConditionalActions.Games.Profile
  alias HllConditionalActions.Rules.Catalog
  alias HllConditionalActions.Rules.Rule
  alias HllConditionalActions.Servers.Server

  @type t :: %__MODULE__{
          server: Server.t(),
          profile: Profile.t(),
          trigger: atom(),
          player_id: String.t() | nil,
          player_name: String.t() | nil,
          player: map() | nil,
          player_profile: map() | nil,
          gamestate: map() | nil,
          roster: %{optional(String.t()) => map()},
          extra: map(),
          event: Event.t() | nil
        }

  @enforce_keys [:server, :profile, :trigger]
  defstruct [
    :server,
    :profile,
    :trigger,
    :player_id,
    :player_name,
    :player,
    :player_profile,
    :gamestate,
    :event,
    roster: %{},
    extra: %{}
  ]

  @doc """
  Builds a context for evaluating rules against one player.

  ## Options

    * `:player_id` / `:player_name` - who the rule is about
    * `:player` - that player's entry from `get_detailed_players`
    * `:player_profile` - their persistent profile, when a rule needs it
    * `:gamestate` - the shared `get_gamestate` snapshot
    * `:roster` - every connected player from the same snapshot, which is what
      the squad conditions are read from
    * `:extra` - values the engine computes per rule (the strike count), kept
      out of the shared fields because they cost a query
    * `:event` - the CRCON event that triggered this evaluation
  """
  @spec build(Server.t(), atom(), keyword()) :: t()
  def build(%Server{} = server, trigger, opts \\ []) do
    player = Keyword.get(opts, :player)

    %__MODULE__{
      server: server,
      profile: Games.profile!(server.game),
      trigger: trigger,
      player: player,
      player_id: Keyword.get(opts, :player_id) || player_field(player, "player_id"),
      player_name: Keyword.get(opts, :player_name) || player_field(player, "name"),
      player_profile: Keyword.get(opts, :player_profile) || player_field(player, "profile"),
      gamestate: Keyword.get(opts, :gamestate),
      roster: Keyword.get(opts, :roster) || %{},
      extra: Keyword.get(opts, :extra) || %{},
      event: Keyword.get(opts, :event)
    }
  end

  @doc """
  Whether any of these rules reads a field that requires the per-player profile
  call.

      iex> alias HllConditionalActions.Engine.Context
      iex> alias HllConditionalActions.Rules.{Condition, Rule}
      iex> rule = %Rule{conditions: [%Condition{field: :sessions_count}]}
      iex> Context.needs_player_profile?([rule])
      true
      iex> Context.needs_player_profile?([%Rule{conditions: [%Condition{field: :kills}]}])
      false
  """
  @spec needs_player_profile?([Rule.t()]) :: boolean()
  def needs_player_profile?(rules) do
    Enum.any?(rules, fn rule ->
      Enum.any?(rule.conditions, &(Catalog.field_group(&1.field) == :profile))
    end)
  end

  @doc """
  The team the player is on, as CRCON reports it (`"allies"` / `"axis"`), or
  `nil` when unknown.
  """
  @spec team(t()) :: String.t() | nil
  def team(%__MODULE__{player: player}) do
    case player_field(player, "team") do
      nil -> nil
      team -> String.downcase(to_string(team))
    end
  end

  @doc """
  Template variables exposed to action messages.

  Keys are strings so `HllConditionalActions.Engine.Template` can look them up
  directly from the `{placeholder}` text.
  """
  @spec variables(t()) :: %{String.t() => String.t()}
  def variables(%__MODULE__{} = context) do
    %{
      "player_name" => context.player_name,
      "player_id" => context.player_id,
      "player_level" => player_field(context.player, "level"),
      "player_role" => role_label(context),
      "team" => team_label(context),
      "unit_name" => player_field(context.player, "unit_name"),
      "clan_tag" => player_field(context.player, "clan_tag"),
      "kills" => player_field(context.player, "kills"),
      "deaths" => player_field(context.player, "deaths"),
      "teamkills" => player_field(context.player, "team_kills"),
      "combat" => player_field(context.player, "combat"),
      "offense" => player_field(context.player, "offense"),
      "defense" => player_field(context.player, "defense"),
      "support" => player_field(context.player, "support"),
      "is_vip" => player_field(context.player, "is_vip"),
      "playtime_minutes" => playtime_minutes(context),
      "map_name" => map_name(context),
      "game_mode" => gamestate_field(context.gamestate, "game_mode"),
      "server_name" => context.server.name,
      "server_player_count" => server_player_count(context),
      "weapon" => context.event && context.event.weapon,
      "target_player_name" => context.event && context.event.target_player_name,
      "message" => context.event && context.event.chat_message
    }
    |> Map.new(fn {key, value} -> {key, stringify(value)} end)
  end

  @doc """
  Reads a key from the detailed player map, returning `nil` when absent.
  """
  @spec player_field(map() | nil, String.t()) :: term()
  def player_field(nil, _key), do: nil
  def player_field(player, key) when is_map(player), do: Map.get(player, key)

  @doc """
  Reads a key from the game state map, returning `nil` when absent.
  """
  @spec gamestate_field(map() | nil, String.t()) :: term()
  def gamestate_field(nil, _key), do: nil
  def gamestate_field(gamestate, key) when is_map(gamestate), do: Map.get(gamestate, key)

  @doc """
  The pretty name of the current map, or `nil`.

  CRCON's game state carries a *layer*, whose own `pretty_name` includes the
  game mode ("Carentan Warfare"). A rule that says "the map is Carentan" means
  the map, so the nested map name wins and the layer name is only a fallback.
  """
  @spec map_name(t()) :: String.t() | nil
  def map_name(%__MODULE__{gamestate: gamestate}) do
    case gamestate_field(gamestate, "current_map") do
      %{"map" => %{"pretty_name" => name}} when is_binary(name) -> name
      %{"pretty_name" => name} when is_binary(name) -> name
      %{"id" => id} when is_binary(id) -> id
      _other -> nil
    end
  end

  @doc """
  Total players on the server right now, or `nil` when the game state is
  unavailable.
  """
  @spec server_player_count(t()) :: integer() | nil
  def server_player_count(%__MODULE__{gamestate: nil}), do: nil

  def server_player_count(%__MODULE__{gamestate: gamestate}) do
    allied = gamestate_field(gamestate, "num_allied_players") || 0
    axis = gamestate_field(gamestate, "num_axis_players") || 0
    allied + axis
  end

  @doc """
  Players on the same team as the context's player, or `nil` when either the
  team or the game state is unknown.
  """
  @spec team_player_count(t()) :: integer() | nil
  def team_player_count(%__MODULE__{gamestate: nil}), do: nil

  def team_player_count(%__MODULE__{} = context) do
    case team(context) do
      "allies" -> gamestate_field(context.gamestate, "num_allied_players")
      "axis" -> gamestate_field(context.gamestate, "num_axis_players")
      _other -> nil
    end
  end

  @doc """
  The current local time on the server, in its configured IANA zone.

  Time-of-day conditions are about the players' evening, not the machine's, so
  they are evaluated against this rather than UTC. A zone the database cannot
  resolve falls back to UTC instead of failing the whole evaluation.
  """
  @spec local_now(t()) :: DateTime.t()
  def local_now(%__MODULE__{server: server}) do
    case DateTime.now(Server.timezone(server)) do
      {:ok, datetime} -> datetime
      _error -> DateTime.utc_now()
    end
  end

  @doc """
  The day name used by the `day_of_week` condition field.

      iex> HllConditionalActions.Engine.Context.day_name(~D[2026-08-17])
      "monday"
  """
  @spec day_name(Date.t() | DateTime.t()) :: String.t()
  def day_name(%DateTime{} = datetime), do: datetime |> DateTime.to_date() |> day_name()

  def day_name(%Date{} = date) do
    Enum.at(
      ~w(monday tuesday wednesday thursday friday saturday sunday),
      Date.day_of_week(date) - 1
    )
  end

  @doc """
  Seconds left in the current match, parsed from CRCON's `"H:MM:SS"` string.

      iex> alias HllConditionalActions.Engine.Context
      iex> Context.parse_time_remaining("1:02:03")
      3723
      iex> Context.parse_time_remaining("nope")
      nil
  """
  @spec parse_time_remaining(String.t() | nil) :: integer() | nil
  def parse_time_remaining(nil), do: nil

  def parse_time_remaining(raw) when is_binary(raw) do
    raw
    |> String.split(":")
    |> Enum.map(&Integer.parse/1)
    |> case do
      [{h, ""}, {m, ""}, {s, ""}] -> h * 3600 + m * 60 + s
      [{m, ""}, {s, ""}] -> m * 60 + s
      _other -> nil
    end
  end

  def parse_time_remaining(_raw), do: nil

  defp role_label(%__MODULE__{} = context) do
    role = player_field(context.player, "role")

    case Profile.fetch_role(context.profile, role) do
      {:ok, %{label: label}} -> label
      :error -> role
    end
  end

  defp team_label(%__MODULE__{} = context) do
    case team(context) do
      nil ->
        nil

      value ->
        case Enum.find(context.profile.teams, &(&1.value == value)) do
          nil -> value
          %{label: label} -> label
        end
    end
  end

  defp playtime_minutes(%__MODULE__{} = context) do
    case player_field(context.player, "map_playtime_seconds") do
      seconds when is_integer(seconds) -> div(seconds, 60)
      _other -> nil
    end
  end

  defp stringify(nil), do: ""
  defp stringify(value) when is_binary(value), do: value
  defp stringify(true), do: "yes"
  defp stringify(false), do: "no"
  defp stringify(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp stringify(value), do: to_string(value)

  # ── Squad ──────────────────────────────────────────────────────────────────

  @doc """
  Everyone in the context player's squad, themselves included.

  Read from the roster the evaluation cycle already fetched
  (`get_detailed_players`), which is the same data CRCON builds its own
  `get_team_view` from - so squad rules cost no extra API call. Players with
  no unit (the commander, or someone still loading) have no squad.
  """
  @spec squad(t()) :: [map()]
  def squad(%__MODULE__{roster: roster}) when map_size(roster) == 0, do: []

  def squad(%__MODULE__{} = context) do
    with unit when is_binary(unit) <- player_field(context.player, "unit_name"),
         team when not is_nil(team) <- team(context) do
      context.roster
      |> Map.values()
      |> Enum.filter(fn player ->
        player_field(player, "unit_name") == unit and
          downcase(player_field(player, "team")) == team
      end)
    else
      _no_squad -> []
    end
  end

  @doc """
  Whether the squad has an officer in it.

  A squad without a leader is the single most common thing an admin
  automates against, and it is why CRCON ships a whole automod for it.
  """
  @spec squad_has_leader?(t()) :: boolean() | nil
  def squad_has_leader?(%__MODULE__{} = context) do
    case squad(context) do
      [] -> nil
      players -> Enum.any?(players, &leader?(context.profile, &1))
    end
  end

  @doc """
  Whether the context player leads their squad.
  """
  @spec squad_leader?(t()) :: boolean() | nil
  def squad_leader?(%__MODULE__{player: nil}), do: nil

  def squad_leader?(%__MODULE__{profile: profile, player: player}), do: leader?(profile, player)

  @doc """
  Whether the context player is the commander.
  """
  @spec commander?(t()) :: boolean() | nil
  def commander?(%__MODULE__{player: nil}), do: nil

  def commander?(%__MODULE__{profile: profile, player: player}) do
    role_of_type?(profile, player, :commander)
  end

  @doc """
  Whether the player's squad is an armor squad, and whether they are alone in
  it. A single tanker holds a vehicle a full crew should be using, which is
  the other automod CRCON ships.
  """
  @spec armor_squad?(t()) :: boolean() | nil
  def armor_squad?(%__MODULE__{profile: profile} = context) do
    case player_field(context.player, "role") do
      nil -> nil
      _role -> role_of_type?(profile, context.player, :armor)
    end
  end

  @spec solo_armor?(t()) :: boolean() | nil
  def solo_armor?(%__MODULE__{} = context) do
    case armor_squad?(context) do
      nil -> nil
      false -> false
      true -> length(squad(context)) <= 1
    end
  end

  # Which roles lead a squad is game data, not a constant: the profile marks
  # them, so Vietnam's helicopter roles are covered without a second list.
  defp leader?(profile, player) do
    leaders = profile |> Profile.squad_leader_roles() |> Enum.map(& &1.value)

    downcase(player_field(player, "role")) in leaders
  end

  defp role_of_type?(profile, player, type) do
    values = profile |> Profile.roles_of_type(type) |> Enum.map(& &1.value)

    downcase(player_field(player, "role")) in values
  end

  defp downcase(nil), do: nil
  defp downcase(value) when is_binary(value), do: String.downcase(value)
  defp downcase(value), do: value

  # ── Chat commands ──────────────────────────────────────────────────────────

  @command_prefixes ["!", "@", "#"]

  @doc """
  The prefixes that turn a chat message into a command.

      iex> HllConditionalActions.Engine.Context.command_prefixes()
      ["!", "@", "#"]
  """
  @spec command_prefixes() :: [String.t()]
  def command_prefixes, do: @command_prefixes

  @doc """
  Whether a chat message is a command.

      iex> alias HllConditionalActions.Engine.Context
      iex> {Context.command?("!vip"), Context.command?("hello")}
      {true, false}
  """
  @spec command?(String.t() | nil) :: boolean()
  def command?(message) when is_binary(message) do
    trimmed = String.trim_leading(message)

    Enum.any?(@command_prefixes, &String.starts_with?(trimmed, &1)) and
      match?({command, _rest} when command != nil, parse_command(message))
  end

  def command?(_message), do: false

  @doc """
  Splits a chat command into its name and the rest of the line.

  The name is downcased so a rule written against `vip` also catches someone
  shouting `!VIP`, and the prefix is dropped - the rule asks for the command,
  not for the punctuation the player happened to use.

      iex> alias HllConditionalActions.Engine.Context
      iex> Context.parse_command("!vip please")
      {"vip", "please"}
      iex> Context.parse_command("!discord")
      {"discord", ""}
      iex> Context.parse_command("just talking")
      {nil, nil}
  """
  @spec parse_command(String.t() | nil) :: {String.t() | nil, String.t() | nil}
  def parse_command(message) when is_binary(message) do
    trimmed = String.trim_leading(message)

    case Enum.find(@command_prefixes, &String.starts_with?(trimmed, &1)) do
      nil ->
        {nil, nil}

      prefix ->
        case trimmed |> String.trim_leading(prefix) |> String.split(" ", parts: 2) do
          [""] -> {nil, nil}
          ["", _rest] -> {nil, nil}
          [command] -> {String.downcase(command), ""}
          [command, rest] -> {String.downcase(command), String.trim(rest)}
        end
    end
  end

  def parse_command(_message), do: {nil, nil}
end
