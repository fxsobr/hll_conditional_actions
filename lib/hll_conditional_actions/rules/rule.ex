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

  alias HllConditionalActions.Games
  alias HllConditionalActions.Rules.Action
  alias HllConditionalActions.Rules.Catalog
  alias HllConditionalActions.Rules.Condition
  alias HllConditionalActions.Servers.Server

  @type t :: %__MODULE__{}

  @min_trigger_interval 10

  # One hour: long enough that a repeat offence inside it is the same
  # episode, short enough that a player is not punished tomorrow for today.
  @default_escalation_window 3600

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

    belongs_to :server, Server

    embeds_many :conditions, Condition, on_replace: :delete
    embeds_many :actions, Action, on_replace: :delete

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
      :escalate
    ])
    |> cast_embed(:conditions, required: true, with: &Condition.changeset/2)
    |> cast_embed(:actions, required: true, with: &Action.changeset/2)
    |> validate_required([:name, :game, :trigger_event, :logical_operator])
    |> validate_length(:name, max: 120)
    |> validate_inclusion(:game, Games.all())
    |> validate_number(:priority, greater_than_or_equal_to: 0)
    |> validate_number(:cooldown_seconds, greater_than_or_equal_to: 0)
    |> validate_number(:max_executions_per_player, greater_than_or_equal_to: 0)
    |> validate_number(:trigger_interval_seconds, greater_than_or_equal_to: @min_trigger_interval)
    |> put_escalation()
    |> validate_at_least_one(:conditions)
    |> validate_at_least_one(:actions)
    |> validate_fields_match_trigger()
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
  Sorts rules the way the engine evaluates them: highest priority first, then
  oldest first so the order is stable.
  """
  @spec sort([t()]) :: [t()]
  def sort(rules) do
    Enum.sort_by(rules, &{-&1.priority, &1.id})
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
          add_error(
            changeset,
            :conditions,
            "#{Enum.map_join(invalid, ", ", &to_string/1)} cannot be used with this trigger"
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
