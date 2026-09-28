defmodule HllConditionalActions.Rules.Rule do
  @moduledoc """
  A conditional rule: *when TRIGGER happens, if CONDITIONS hold, run ACTIONS*.

  ## Scope

  A rule always declares the `game` it is written for, because the available
  roles, teams and map names differ between Hell Let Loose and Hell Let Loose:
  Vietnam. It may additionally pin itself to one `server`:

    * `server_id` set - the rule runs on that server only
    * `server_id` nil - the rule runs on every enabled server of the same game

  That makes it cheap to write one rule for a whole fleet while still allowing
  per-server overrides.

  ## Rate limiting

  `cooldown_seconds` is the minimum gap between two executions for the same
  player, and `max_executions_per_player` caps executions per player within a
  24 hour window (`0` disables either check). Both are enforced by
  `HllConditionalActions.Engine.Limiter` against the `rule_executions` table.

  The builder shows each limit as an on/off switch with a friendly duration
  (virtual `cooldown_enabled`, `cooldown_value`, `cooldown_unit` and
  `cap_enabled`); `put_limits/1` folds them back into the two columns.

  ## Exemptions

  `exemptions` names the players the rule never applies to - VIPs, players
  carrying certain CRCON flags, specific ids. See
  `HllConditionalActions.Rules.Exemptions`.

  ## Escalation

  With `escalation_window_seconds` at `0` a rule runs *every* action on every
  firing. Set it, and the action list becomes a ladder instead: the engine
  counts how many times the rule already fired for that player inside the
  window and runs only the matching step - first offence runs the first
  action, second the second, and everything past the end of the list repeats
  the last one.

  That is how an admin writes "warn, warn again, then punish, then kick"
  as a single rule: four actions, one window. The counting is done by
  `HllConditionalActions.Engine.Escalation` against the same
  `rule_executions` table the limiter uses, so it survives restarts.

  The builder asks the question as a yes/no - *does this rule escalate?* -
  because "a number where zero means off" is a puzzle, not a setting. The
  virtual `escalate` field is that switch: turning it off zeroes the window,
  turning it on gives it an hour if it had none, and the changeset keeps the
  two telling the same story.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias HllConditionalActions.Engine.Template
  alias HllConditionalActions.Games
  alias HllConditionalActions.Rules.Action
  alias HllConditionalActions.Rules.Catalog
  alias HllConditionalActions.Rules.Condition
  alias HllConditionalActions.Rules.Exemptions
  alias HllConditionalActions.Servers.Server

  @type t :: %__MODULE__{}

  @min_trigger_interval 10

  # One hour: long enough that a repeat offence inside it is the same
  # episode, short enough that a player is not punished tomorrow for today.
  @default_escalation_window 3600

  # What a limit starts at when its switch is turned on.
  @default_cooldown 60
  @default_cap 3

  @duration_units %{"s" => 1, "min" => 60, "h" => 3600}

  schema "rules" do
    field :name, :string
    field :description, :string
    field :enabled, :boolean, default: true
    # Evaluate and record, but describe the actions instead of sending them.
    field :simulation, :boolean, default: false
    field :priority, :integer, default: 0
    # A free-text folder, so a fleet's rules stay navigable past a dozen.
    field :group, :string
    field :game, Ecto.Enum, values: [:hll, :hllv], default: :hll
    field :trigger_event, Ecto.Enum, values: Catalog.triggers(), default: :player_connected
    field :trigger_interval_seconds, :integer, default: 60
    field :logical_operator, Ecto.Enum, values: Catalog.logical_operators(), default: :and
    field :cooldown_seconds, :integer, default: 0
    field :max_executions_per_player, :integer, default: 0
    # > 0 turns the action list into an escalation ladder; see the moduledoc.
    field :escalation_window_seconds, :integer, default: 0
    # The builder's switch over that window; never stored.
    field :escalate, :boolean, virtual: true
    # The builder's plain-language view of the limits; never stored. See
    # `put_limits/1` for how they map onto the two columns above.
    field :cooldown_enabled, :boolean, virtual: true
    field :cooldown_value, :integer, virtual: true
    field :cooldown_unit, :string, virtual: true
    field :cap_enabled, :boolean, virtual: true
    # A temporary pause: the engine skips the rule until this moment passes.
    field :paused_until, :utc_datetime
    field :pause_reason, :string
    # Pending edits to a live rule, as a `Snapshot` the engine never reads
    # until they are published.
    field :draft, :map
    field :draft_user_name, :string
    field :draft_updated_at, :utc_datetime

    belongs_to :server, Server

    embeds_many :conditions, Condition, on_replace: :delete
    embeds_many :actions, Action, on_replace: :delete
    embeds_one :exemptions, Exemptions, on_replace: :update

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for creating or updating a rule.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [
      :name,
      :description,
      :enabled,
      :simulation,
      :priority,
      :group,
      :game,
      :server_id,
      :trigger_event,
      :trigger_interval_seconds,
      :logical_operator,
      :cooldown_seconds,
      :max_executions_per_player,
      :escalation_window_seconds,
      :escalate,
      :cooldown_enabled,
      :cooldown_value,
      :cooldown_unit,
      :cap_enabled
    ])
    |> cast_embed(:conditions, required: true, with: &Condition.changeset/2)
    |> cast_embed(:actions, required: true, with: &Action.changeset/2)
    |> cast_embed(:exemptions, with: &Exemptions.changeset/2)
    |> validate_required([:name, :game, :trigger_event, :logical_operator])
    |> validate_length(:name, max: 120)
    |> validate_inclusion(:game, Games.all())
    |> validate_number(:priority, greater_than_or_equal_to: 0)
    |> validate_number(:cooldown_seconds, greater_than_or_equal_to: 0)
    |> validate_number(:max_executions_per_player, greater_than_or_equal_to: 0)
    |> validate_number(:trigger_interval_seconds, greater_than_or_equal_to: @min_trigger_interval)
    |> put_limits()
    |> put_escalation()
    |> update_change(:group, &normalize_group/1)
    |> validate_at_least_one(:conditions)
    |> validate_at_least_one(:actions)
    |> validate_fields_match_trigger()
    |> validate_placeholders()
    |> validate_server_game()
    |> assoc_constraint(:server)
  end

  @doc """
  Whether this rule applies to a server.

      iex> alias HllConditionalActions.Rules.Rule
      iex> server = %HllConditionalActions.Servers.Server{id: 1, game: :hll}
      iex> Rule.applies_to?(%Rule{game: :hll, server_id: nil}, server)
      true
      iex> Rule.applies_to?(%Rule{game: :hll, server_id: 2}, server)
      false
      iex> Rule.applies_to?(%Rule{game: :hllv, server_id: nil}, server)
      false
  """
  @spec applies_to?(t(), Server.t()) :: boolean()
  def applies_to?(%__MODULE__{game: game, server_id: nil}, %Server{game: game}), do: true
  def applies_to?(%__MODULE__{server_id: id, game: game}, %Server{id: id, game: game}), do: true
  def applies_to?(%__MODULE__{}, %Server{}), do: false

  @doc """
  Whether a rule is temporarily paused at `now`.

  The pause ends on its own: once `paused_until` is in the past the rule is
  live again, with no job needed to clear the field.
  """
  @spec paused?(t(), DateTime.t()) :: boolean()
  def paused?(rule, now \\ DateTime.utc_now())
  def paused?(%__MODULE__{paused_until: nil}, _now), do: false
  def paused?(%__MODULE__{paused_until: until}, now), do: DateTime.compare(until, now) == :gt

  @doc """
  Builds a changeset that pauses a rule until a moment, or resumes it with `nil`.
  """
  @spec pause_changeset(t(), DateTime.t() | nil, String.t() | nil) :: Ecto.Changeset.t()
  def pause_changeset(rule, until, reason) do
    reason = if until, do: normalize_reason(reason)

    rule
    |> change(paused_until: until && DateTime.truncate(until, :second), pause_reason: reason)
    |> validate_length(:pause_reason, max: 200)
  end

  defp normalize_reason(reason) when is_binary(reason) do
    case String.trim(reason) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_reason(_reason), do: nil

  @doc """
  Normalizes a group name: trims and collapses whitespace, so "Seeding " and
  "seeding" do not become two groups. Matching an existing group ignoring case
  is done by `HllConditionalActions.Rules`, which knows the groups in use.

      iex> HllConditionalActions.Rules.Rule.normalize_group("  Seeding   rules ")
      "Seeding rules"
      iex> HllConditionalActions.Rules.Rule.normalize_group("   ")
      nil
  """
  @spec normalize_group(term()) :: String.t() | nil
  def normalize_group(group) when is_binary(group) do
    case group |> String.split() |> Enum.join(" ") do
      "" -> nil
      value -> value
    end
  end

  def normalize_group(_group), do: nil

  @doc """
  Sorts rules the way the engine evaluates them: highest priority first, then
  oldest first so the order is stable.
  """
  @spec sort([t()]) :: [t()]
  def sort(rules) do
    Enum.sort_by(rules, &{-&1.priority, &1.id})
  end

  @doc """
  Splits seconds into the largest unit that holds them exactly, for the
  builder's value + unit inputs.

      iex> alias HllConditionalActions.Rules.Rule
      iex> {Rule.split_duration(90), Rule.split_duration(600), Rule.split_duration(7200)}
      {{90, "s"}, {10, "min"}, {2, "h"}}
  """
  @spec split_duration(non_neg_integer()) :: {non_neg_integer(), String.t()}
  def split_duration(seconds) when is_integer(seconds) and seconds > 0 do
    cond do
      rem(seconds, 3600) == 0 -> {div(seconds, 3600), "h"}
      rem(seconds, 60) == 0 -> {div(seconds, 60), "min"}
      true -> {seconds, "s"}
    end
  end

  def split_duration(_seconds), do: {0, "s"}

  # The builder speaks in switches and "value + unit"; the API, the importer
  # and the engine speak in seconds and a count where zero means off. This
  # keeps the two in step, whichever side the caller set - the same deal as
  # `put_escalation/1`.
  defp put_limits(changeset) do
    changeset
    |> put_cooldown()
    |> put_cap()
  end

  defp put_cooldown(changeset) do
    seconds = typed_cooldown(changeset)

    enabled =
      case get_field(changeset, :cooldown_enabled) do
        nil -> seconds > 0
        value -> value
      end

    changeset =
      if enabled,
        do: validate_number(changeset, :cooldown_value, greater_than: 0),
        else: changeset

    invalid? = Keyword.has_key?(changeset.errors, :cooldown_value)
    seconds = cooldown_seconds(changeset, enabled, seconds, invalid?)

    changeset
    |> put_change(:cooldown_enabled, enabled)
    |> put_change(:cooldown_seconds, seconds)
    |> put_cooldown_display(seconds, invalid?)
  end

  # Seconds as the builder typed them (value x unit), else as stored.
  defp typed_cooldown(changeset) do
    case get_change(changeset, :cooldown_value) do
      value when is_integer(value) ->
        unit = get_field(changeset, :cooldown_unit) || "s"
        value * Map.get(@duration_units, unit, 1)

      _no_builder_value ->
        get_field(changeset, :cooldown_seconds) || 0
    end
  end

  defp cooldown_seconds(_changeset, false, _seconds, _invalid?), do: 0
  defp cooldown_seconds(_changeset, true, seconds, _invalid?) when seconds > 0, do: seconds

  defp cooldown_seconds(changeset, true, _seconds, true),
    do: get_field(changeset, :cooldown_seconds) || 0

  defp cooldown_seconds(_changeset, true, _seconds, false), do: @default_cooldown

  # A value the admin is still fixing is left as typed, so the error sits
  # next to what they wrote.
  defp put_cooldown_display(changeset, seconds, invalid?) do
    {value, unit} =
      if seconds > 0,
        do: split_duration(seconds),
        else: {@default_cooldown, get_field(changeset, :cooldown_unit) || "s"}

    changeset = put_change(changeset, :cooldown_unit, unit)
    if invalid?, do: changeset, else: put_change(changeset, :cooldown_value, value)
  end

  defp put_cap(changeset) do
    count = get_field(changeset, :max_executions_per_player) || 0

    enabled =
      case get_field(changeset, :cap_enabled) do
        nil -> count > 0
        value -> value
      end

    count =
      cond do
        not enabled -> 0
        count > 0 -> count
        true -> @default_cap
      end

    changeset
    |> put_change(:cap_enabled, enabled)
    |> put_change(:max_executions_per_player, count)
  end

  # A `{placeholder}` the engine cannot fill is sent to the game as written,
  # so a typo would reach players. Caught here, with the trigger in hand:
  # `{weapon}` is fine on a kill and meaningless on a connect.
  defp validate_placeholders(changeset) do
    trigger = get_field(changeset, :trigger_event)
    actions = get_field(changeset, :actions) || []

    unknown =
      for action <- actions,
          action.type in Catalog.action_types(),
          {key, _type, opts} <- Catalog.action_params(action.type),
          opts[:template],
          name <- Template.unknown_placeholders(template_text(action, key), trigger),
          uniq: true,
          do: name

    case unknown do
      [] ->
        changeset

      names ->
        add_error(changeset, :actions, "unknown placeholders: %{names}",
          names: Enum.map_join(names, ", ", &"{#{&1}}")
        )
    end
  end

  defp template_text(action, key) do
    case Map.get(action.parameters || %{}, to_string(key)) do
      text when is_binary(text) -> text
      _other -> nil
    end
  end

  # Keeps the switch and the window telling the same story, whichever of the
  # two the caller set: the API and the importer only know the window, the
  # builder only knows the switch.
  defp put_escalation(changeset) do
    window = get_field(changeset, :escalation_window_seconds) || 0

    escalate =
      case get_field(changeset, :escalate) do
        nil -> window > 0
        value -> value
      end

    window =
      cond do
        not escalate -> 0
        window > 0 -> window
        true -> @default_escalation_window
      end

    changeset
    |> put_change(:escalate, escalate)
    |> put_change(:escalation_window_seconds, window)
  end

  defp validate_at_least_one(changeset, field) do
    case get_field(changeset, field) do
      list when is_list(list) and list != [] -> changeset
      _empty -> add_error(changeset, field, "must have at least one entry")
    end
  end

  # A rule triggered by `player_connected` cannot inspect `weapon`: that value
  # only exists on kill events. Catching it here beats a rule that silently
  # never fires.
  defp validate_fields_match_trigger(changeset) do
    trigger = get_field(changeset, :trigger_event)
    conditions = get_field(changeset, :conditions) || []

    if is_nil(trigger) do
      changeset
    else
      allowed = Catalog.fields_for_trigger(trigger)

      conditions
      |> Enum.map(& &1.field)
      |> Enum.reject(&(&1 in allowed))
      |> Enum.uniq()
      |> case do
        [] ->
          changeset

        invalid ->
          add_error(changeset, :conditions, "%{fields} cannot be used with this trigger",
            fields: Enum.map_join(invalid, ", ", &to_string/1)
          )
      end
    end
  end

  defp validate_server_game(changeset) do
    with server_id when not is_nil(server_id) <- get_field(changeset, :server_id),
         %Server{} = server <- get_field(changeset, :server),
         true <- server.game != get_field(changeset, :game) do
      add_error(changeset, :server_id, "runs a different game than this rule")
    else
      _ok -> changeset
    end
  end
end
