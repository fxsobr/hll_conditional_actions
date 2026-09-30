defmodule HllConditionalActions.Progression.Season do
  @moduledoc """
  A season: a leaderboard over `duration_days`, counting one metric match
  after match, on one server or across several servers of the same game -
  a community with three HLL servers can run one season for all of them. When it ends, the top `winners_count` players who
  played at least `min_matches` get VIP for `reward_vip_hours` on every server of the season, and - with
  `auto_renew` - the next season of the same length starts right away.

  `scoring` decides how players are ranked - see
  `HllConditionalActions.Progression.Scoring`: the sum or the average of
  `metric`, a mix of stats by `weights`, or a rating built from the
  formula in `rating` (see `HllConditionalActions.Progression.Rating`).
  """

  use Ecto.Schema
  use Gettext, backend: HllConditionalActionsWeb.Gettext

  import Ecto.Changeset

  alias HllConditionalActions.Progression.Metrics
  alias HllConditionalActions.Progression.Rating
  alias HllConditionalActions.Progression.Scoring

  @type t :: %__MODULE__{}

  schema "seasons" do
    field :name, :string
    field :game, Ecto.Enum, values: [:hll, :hllv], default: :hll
    field :rating, :map, default: %{}

    many_to_many :servers, HllConditionalActions.Servers.Server,
      join_through: "season_servers",
      on_replace: :delete

    field :scoring, Ecto.Enum, values: Scoring.methods(), default: :sum
    field :metric, Ecto.Enum, values: Metrics.match()
    field :weights, :map, default: %{}
    field :per_match, :boolean, default: false
    field :starts_at, :utc_datetime
    field :ends_at, :utc_datetime
    field :duration_days, :integer
    field :winners_count, :integer, default: 3
    field :min_matches, :integer, default: 3
    field :reward_vip_hours, :integer, default: 168
    field :auto_renew, :boolean, default: true
    field :status, Ecto.Enum, values: [:active, :finished], default: :active
    field :finished_at, :utc_datetime

    has_many :scores, HllConditionalActions.Progression.SeasonScore

    timestamps(type: :utc_datetime)
  end

  @doc """
  `servers` are the servers the season runs on, already loaded (the context
  turns the submitted ids into them); `nil` keeps the season's current ones.
  """
  @spec changeset(t(), map(), [HllConditionalActions.Servers.Server.t()] | nil) ::
          Ecto.Changeset.t()
  def changeset(season, attrs, servers \\ nil) do
    season
    |> cast(attrs, [
      :name,
      :scoring,
      :rating,
      :metric,
      :weights,
      :per_match,
      :starts_at,
      :duration_days,
      :winners_count,
      :min_matches,
      :reward_vip_hours,
      :auto_renew
    ])
    |> validate_required([:name, :scoring, :duration_days, :winners_count])
    |> put_servers(servers)
    |> validate_scoring()
    |> validate_length(:name, max: 60)
    |> validate_number(:duration_days, greater_than: 0, less_than_or_equal_to: 365)
    |> validate_number(:winners_count, greater_than: 0, less_than_or_equal_to: 50)
    |> validate_number(:min_matches, greater_than_or_equal_to: 0)
    |> validate_number(:reward_vip_hours, greater_than_or_equal_to: 0)
    |> put_starts_at()
    |> put_ends_at()
  end

  # One game per season: a kill in Vietnam and one in Normandy are not the
  # same thing to rank. The season takes the game of its servers.
  defp put_servers(changeset, nil) do
    if changeset.data.id,
      do: changeset,
      else: add_error(changeset, :servers, dgettext_noop("errors", "pick at least one server"))
  end

  defp put_servers(changeset, []),
    do: add_error(changeset, :servers, dgettext_noop("errors", "pick at least one server"))

  defp put_servers(changeset, servers) do
    case servers |> Enum.map(& &1.game) |> Enum.uniq() do
      [game] ->
        changeset |> put_change(:game, game) |> put_assoc(:servers, servers)

      _mixed ->
        add_error(
          changeset,
          :servers,
          dgettext_noop("errors", "the servers of a season must all run the same game")
        )
    end
  end

  # A sum or an average needs the stat it counts; a mix needs at least one
  # stat that weighs something. Weights keep up to two decimals.
  defp validate_scoring(changeset) do
    case get_field(changeset, :scoring) do
      scoring when scoring in [:sum, :average] -> validate_required(changeset, [:metric])
      :weighted -> validate_weights(changeset)
      :elo -> put_change(changeset, :rating, Rating.normalize(get_field(changeset, :rating)))
    end
  end

  defp validate_weights(changeset) do
    weights =
      Map.new(Scoring.weighted_metrics(), fn metric ->
        {to_string(metric), Scoring.weight(get_field(changeset, :weights), metric)}
      end)

    changeset = put_change(changeset, :weights, weights)

    if Enum.all?(weights, fn {_metric, weight} -> weight == 0 end),
      do:
        add_error(changeset, :weights, dgettext_noop("errors", "give at least one stat a weight")),
      else: changeset
  end

  defp put_starts_at(changeset) do
    case get_field(changeset, :starts_at) do
      nil -> put_change(changeset, :starts_at, DateTime.truncate(DateTime.utc_now(), :second))
      _set -> changeset
    end
  end

  defp put_ends_at(changeset) do
    with %DateTime{} = starts_at <- get_field(changeset, :starts_at),
         days when is_integer(days) and days > 0 <- get_field(changeset, :duration_days) do
      put_change(changeset, :ends_at, DateTime.add(starts_at, days, :day))
    else
      _incomplete -> changeset
    end
  end
end
