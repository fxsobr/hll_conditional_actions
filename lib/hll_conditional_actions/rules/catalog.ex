defmodule HllConditionalActions.Rules.Catalog do
  @moduledoc """
  The vocabulary a conditional rule is written in.

  A rule reads as: *when TRIGGER happens, if CONDITIONS hold, run ACTIONS*.
  This module is the single source of truth for what can appear in each of
  those three slots, which keeps the Ecto schemas, the rule builder UI and the
  engine from drifting apart.

  Everything here is data (atoms, types, parameter specs) and carries no user
  facing text; `HllConditionalActionsWeb.Labels` owns the translated labels so
  that `mix gettext.extract` can find them.

  ## Game differences

  Most of the vocabulary is shared between Hell Let Loose and Hell Let Loose:
  Vietnam. Where a field's *values* differ (roles, teams, game modes) the field
  declares an `:options` source that is resolved against the server's
  `HllConditionalActions.Games.Profile` at render time.
  """

  alias HllConditionalActions.Games

  # ── Trigger events ─────────────────────────────────────────────────────────

  @triggers [
    player_connected: %{scope: :player},
    player_disconnected: %{scope: :player},
    player_kill: %{scope: :player},
    player_death: %{scope: :player},
    player_team_kill: %{scope: :player},
    player_chat: %{scope: :player},
    chat_command: %{scope: :player},
    team_switch: %{scope: :player},
    match_start: %{scope: :all_players},
    match_end: %{scope: :all_players},
    periodic: %{scope: :all_players}
  ]

  @doc """
  Every trigger event a rule can subscribe to.

      iex> :player_kill in HllConditionalActions.Rules.Catalog.triggers()
      true
  """
  @spec triggers() :: [atom()]
  def triggers, do: Keyword.keys(@triggers)

  @doc """
  Whether a trigger fires for a single player or sweeps every connected player.

      iex> alias HllConditionalActions.Rules.Catalog
      iex> {Catalog.trigger_scope(:player_kill), Catalog.trigger_scope(:periodic)}
      {:player, :all_players}
  """
  @spec trigger_scope(atom()) :: :player | :all_players
  def trigger_scope(trigger) do
    @triggers |> Keyword.fetch!(trigger) |> Map.fetch!(:scope)
  end

  @doc """
  Triggers that sweep every connected player instead of one.
  """
  @spec batch_triggers() :: [atom()]
  def batch_triggers do
    Enum.filter(triggers(), &(trigger_scope(&1) == :all_players))
  end

  # ── Condition fields ───────────────────────────────────────────────────────

  # `group` drives the optgroups in the rule builder.
  # `type` drives which operators are offered and how values are cast.
  # `options` names a source of allowed values, resolved per game profile.
  # `requires` marks fields that are only meaningful for certain triggers.
  @fields [
    always_true: %{group: :general, type: :boolean},
    player_name: %{group: :player, type: :string},
    player_id: %{group: :player, type: :string},
    player_level: %{group: :player, type: :integer},
    is_vip: %{group: :player, type: :boolean},
    player_role: %{group: :player, type: :string, options: :roles},
    player_team: %{group: :player, type: :string, options: :teams},
    player_unit_name: %{group: :player, type: :string},
    is_squad_leader: %{group: :squad, type: :boolean},
    is_commander: %{group: :squad, type: :boolean},
    squad_has_leader: %{group: :squad, type: :boolean},
    squad_size: %{group: :squad, type: :integer},
    squad_is_armor: %{group: :squad, type: :boolean},
    squad_is_solo_armor: %{group: :squad, type: :boolean},
    clan_tag: %{group: :player, type: :string},
    platform: %{group: :player, type: :string},
    kills: %{group: :match_stats, type: :integer},
    deaths: %{group: :match_stats, type: :integer},
    kill_death_ratio: %{group: :match_stats, type: :float},
    teamkills: %{group: :match_stats, type: :integer},
    combat_score: %{group: :match_stats, type: :integer},
    offense_score: %{group: :match_stats, type: :integer},
    defense_score: %{group: :match_stats, type: :integer},
    support_score: %{group: :match_stats, type: :integer},
    kills_per_minute: %{group: :match_stats, type: :float},
    deaths_per_minute: %{group: :match_stats, type: :float},
    playtime_seconds: %{group: :match_stats, type: :integer},
    total_playtime_seconds: %{group: :profile, type: :integer},
    sessions_count: %{group: :profile, type: :integer},
    penalty_count: %{group: :profile, type: :integer},
    flags: %{group: :profile, type: :list},
    server_player_count: %{group: :server, type: :integer},
    allied_player_count: %{group: :server, type: :integer},
    axis_player_count: %{group: :server, type: :integer},
    team_balance: %{group: :server, type: :integer},
    allied_score: %{group: :server, type: :integer},
    axis_score: %{group: :server, type: :integer},
    team_player_count: %{group: :server, type: :integer},
    queue_count: %{group: :server, type: :integer},
    map_name: %{group: :server, type: :string},
    game_mode: %{group: :server, type: :string, options: :game_modes},
    match_time_remaining: %{group: :server, type: :integer},
    hour_of_day: %{group: :schedule, type: :integer},
    day_of_week: %{group: :schedule, type: :string, options: :days_of_week},
    message_content: %{group: :event, type: :string, requires: [:player_chat, :chat_command]},
    message_scope: %{group: :event, type: :string, requires: [:player_chat, :chat_command]},
    message_team: %{
      group: :event,
      type: :string,
      requires: [:player_chat, :chat_command],
      options: :teams
    },
    weapon: %{
      group: :event,
      type: :string,
      requires: [:player_kill, :player_death, :player_team_kill]
    },
    target_player_name: %{
      group: :event,
      type: :string,
      requires: [:player_kill, :player_death, :player_team_kill]
    },
    event_action: %{group: :event, type: :string},
    strikes: %{group: :general, type: :integer},
    command: %{group: :event, type: :string, requires: [:chat_command]},
    command_args: %{group: :event, type: :string, requires: [:chat_command]}
  ]

  @days_of_week ~w(monday tuesday wednesday thursday friday saturday sunday)

  @field_groups [:general, :player, :squad, :match_stats, :profile, :server, :schedule, :event]

  @doc """
  Every condition field.
  """
  @spec fields() :: [atom()]
  def fields, do: Keyword.keys(@fields)

  @doc """
  The condition field groups, in display order.
  """
  @spec field_groups() :: [atom()]
  def field_groups, do: @field_groups

  @doc """
  The value type of a condition field, which decides how the engine casts it.

      iex> alias HllConditionalActions.Rules.Catalog
      iex> {Catalog.field_type(:kills), Catalog.field_type(:player_name)}
      {:integer, :string}
  """
  @spec field_type(atom()) :: :string | :integer | :float | :boolean | :list
  def field_type(field), do: @fields |> Keyword.fetch!(field) |> Map.fetch!(:type)

  @doc """
  The group a condition field belongs to.
  """
  @spec field_group(atom()) :: atom()
  def field_group(field), do: @fields |> Keyword.fetch!(field) |> Map.fetch!(:group)

  @doc """
  Condition fields belonging to a group, in declaration order.
  """
  @spec fields_in_group(atom()) :: [atom()]
  def fields_in_group(group) do
    for {field, spec} <- @fields, spec.group == group, do: field
  end

  @doc """
  The fields that make sense for a trigger.

  Event fields only carry a value for the trigger that produced them: asking
  for `:weapon` on a `:player_connected` rule would always compare against
  `nil`, so the builder hides it.

      iex> alias HllConditionalActions.Rules.Catalog
      iex> :weapon in Catalog.fields_for_trigger(:player_kill)
      true
      iex> :weapon in Catalog.fields_for_trigger(:player_connected)
      false
  """
  @spec fields_for_trigger(atom()) :: [atom()]
  def fields_for_trigger(trigger) do
    for {field, spec} <- @fields, available_for?(spec, trigger), do: field
  end

  # A field without a `:requires` list is available everywhere. This is a plain
  # function rather than an assignment inside the comprehension, because an
  # assignment there also acts as a filter and would drop every field whose
  # `:requires` is nil - which is nearly all of them.
  defp available_for?(spec, trigger) do
    case Map.get(spec, :requires) do
      nil -> true
      requires -> trigger in requires
    end
  end

  @doc """
  Resolves the allowed values of a field for a game, or `nil` when the field
  takes free text.

      iex> alias HllConditionalActions.Rules.Catalog
      iex> Catalog.field_options(:player_team, :hllv)
      [{"South", "allies"}, {"North", "axis"}]

      iex> HllConditionalActions.Rules.Catalog.field_options(:player_name, :hll)
      nil
  """
  @spec field_options(atom(), Games.Profile.game()) :: [{String.t(), String.t()}] | nil
  def field_options(field, game) do
    case Keyword.fetch!(@fields, field) do
      %{options: :days_of_week} -> days_of_week()
      %{options: source} -> profile_options(source, game)
      _no_options -> nil
    end
  end

  defp profile_options(source, game) do
    case Games.fetch_profile(game) do
      {:ok, profile} ->
        case source do
          :roles -> Games.Profile.role_options(profile)
          :teams -> Games.Profile.team_options(profile)
          :game_modes -> Games.Profile.game_mode_options(profile)
        end

      :error ->
        nil
    end
  end

  @doc """
  Day names as `{label, value}` pairs, Monday first.

  The values are what `HllConditionalActions.Engine.Evaluator` produces from
  `Date.day_of_week/1`, and the labels are translated in the UI.

      iex> HllConditionalActions.Rules.Catalog.days_of_week() |> List.first()
      {"monday", "monday"}
  """
  @spec days_of_week() :: [{String.t(), String.t()}]
  def days_of_week do
    Enum.map(@days_of_week, &{&1, &1})
  end

  # ── Operators ──────────────────────────────────────────────────────────────

  @operators [
    equal: [:string, :integer, :float, :boolean],
    not_equal: [:string, :integer, :float, :boolean],
    greater_than: [:integer, :float],
    greater_than_or_equal: [:integer, :float],
    less_than: [:integer, :float],
    less_than_or_equal: [:integer, :float],
    contains: [:string, :list],
    not_contains: [:string, :list],
    starts_with: [:string],
    ends_with: [:string],
    regex_match: [:string],
    in_list: [:string, :integer],
    not_in_list: [:string, :integer]
  ]

  @doc """
  Every comparison operator.
  """
  @spec operators() :: [atom()]
  def operators, do: Keyword.keys(@operators)

  @doc """
  The operators that are valid for a field.

      iex> alias HllConditionalActions.Rules.Catalog
      iex> Catalog.operators_for_field(:is_vip)
      [:equal, :not_equal]
  """
  @spec operators_for_field(atom()) :: [atom()]
  def operators_for_field(field) do
    type = field_type(field)
    for {operator, types} <- @operators, type in types, do: operator
  end

  @doc """
  Whether an operator takes a comma separated list of values.
  """
  @spec list_operator?(atom()) :: boolean()
  def list_operator?(operator), do: operator in [:in_list, :not_in_list]

  # ── Logical operators ──────────────────────────────────────────────────────

  @logical_operators [:and, :or, :nand, :nor]

  @doc """
  How a rule combines its conditions.
  """
  @spec logical_operators() :: [atom()]
  def logical_operators, do: @logical_operators

  # ── Actions ────────────────────────────────────────────────────────────────

  # Each parameter is `{key, type, opts}`; `opts` may carry `:required`,
  # `:default` and `:min`. `template: true` marks text that goes through
  # `HllConditionalActions.Engine.Template`.
  @actions [
    message_player: [
      {:message, :text, required: true, template: true}
    ],
    message_all_players: [
      {:message, :text, required: true, template: true}
    ],
    broadcast_message: [
      {:message, :text, required: true, template: true}
    ],
    temporary_broadcast: [
      {:message, :text, required: true, template: true},
      {:duration_seconds, :integer, required: true, default: 60, min: 5}
    ],
    set_welcome_message: [
      {:message, :text, required: true, template: true}
    ],
    punish_player: [
      {:reason, :text, required: true, template: true}
    ],
    kick_player: [
      {:reason, :text, required: true, template: true}
    ],
    temp_ban_player: [
      {:reason, :text, required: true, template: true},
      {:duration_hours, :integer, required: true, default: 2, min: 1}
    ],
    perma_ban_player: [
      {:reason, :text, required: true, template: true}
    ],
    switch_player_team: [],
    switch_player_on_death: [],
    add_player_flag: [
      {:flag, :string, required: true},
      {:comment, :string, required: false, template: true}
    ],
    remove_player_flag: [
      {:flag, :string, required: true}
    ],
    add_to_watchlist: [
      {:reason, :text, required: true, template: true}
    ],
    remove_from_watchlist: [],
    grant_vip: [
      {:description, :string, required: true, template: true},
      {:duration_hours, :integer, required: false, default: 24, min: 0}
    ],
    remove_vip: [],
    blacklist_player: [
      {:blacklist_id, :integer, required: true, default: 0, min: 0},
      {:reason, :text, required: true, template: true},
      {:duration_hours, :integer, required: false, default: 0, min: 0}
    ],
    send_discord_webhook: [
      {:webhook_url, :string, required: true},
      {:message, :text, required: true, template: true}
    ]
  ]

  @doc """
  Every action a rule can run.
  """
  @spec action_types() :: [atom()]
  def action_types, do: Keyword.keys(@actions)

  # What each action *does to* a player, which is how an admin looks for one:
  # "I want to talk to them" / "I want to punish them" / "I want to mark them".
  @action_groups [
    messaging: [
      :message_player,
      :message_all_players,
      :broadcast_message,
      :temporary_broadcast,
      :set_welcome_message
    ],
    punishment: [
      :punish_player,
      :kick_player,
      :temp_ban_player,
      :perma_ban_player,
      :blacklist_player
    ],
    team: [:switch_player_team, :switch_player_on_death],
    marking: [
      :add_player_flag,
      :remove_player_flag,
      :add_to_watchlist,
      :remove_from_watchlist,
      :grant_vip,
      :remove_vip
    ],
    integrations: [:send_discord_webhook]
  ]

  @doc """
  The action groups, in display order.
  """
  @spec action_groups() :: [atom()]
  def action_groups, do: Keyword.keys(@action_groups)

  @doc """
  The actions of a group.

      iex> :kick_player in HllConditionalActions.Rules.Catalog.actions_in_group(:punishment)
      true
  """
  @spec actions_in_group(atom()) :: [atom()]
  def actions_in_group(group), do: Keyword.get(@action_groups, group, [])

  @doc """
  The parameter specification of an action.

      iex> HllConditionalActions.Rules.Catalog.action_params(:temp_ban_player)
      [
        {:reason, :text, [required: true, template: true]},
        {:duration_hours, :integer, [required: true, default: 2, min: 1]}
      ]
  """
  @spec action_params(atom()) :: [{atom(), atom(), keyword()}]
  def action_params(action_type), do: Keyword.fetch!(@actions, action_type)

  @doc """
  The parameter keys an action requires.

      iex> HllConditionalActions.Rules.Catalog.required_action_params(:temp_ban_player)
      [:reason, :duration_hours]
  """
  @spec required_action_params(atom()) :: [atom()]
  def required_action_params(action_type) do
    for {key, _type, opts} <- action_params(action_type), opts[:required], do: key
  end

  @doc """
  Default parameters for a newly added action.
  """
  @spec default_action_params(atom()) :: map()
  def default_action_params(action_type) do
    for {key, _type, opts} <- action_params(action_type),
        default = opts[:default],
        into: %{},
        do: {to_string(key), default}
  end

  @doc """
  Actions that target the player the rule triggered for, as opposed to the
  whole server. Used by the builder to warn about server-wide actions on
  per-player triggers.
  """
  @spec player_scoped?(atom()) :: boolean()
  def player_scoped?(action_type) do
    action_type not in [
      :message_all_players,
      :broadcast_message,
      :temporary_broadcast,
      :set_welcome_message
    ]
  end
end
