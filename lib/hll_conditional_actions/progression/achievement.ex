defmodule HllConditionalActions.Progression.Achievement do
  @moduledoc """
  An achievement: reach `threshold` in `metric`, within one match (`:match`)
  or over a player's whole career on the server (`:career`), and receive the
  reward - VIP for some hours, a flag on the player's CRCON profile, and an
  announcement in game.

  In simulation it is unlocked and recorded as usual, but nothing reaches
  the game, the same way a rule in simulation behaves.

  An achievement belongs to one server: each community sets its own goals
  and rewards, and career counts are per server anyway. One without a server
  (from before achievements were per server) applies on every server.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias HllConditionalActions.Progression.Metrics

  @type t :: %__MODULE__{}

  @tiers [:bronze, :silver, :gold, :legendary]

  schema "achievements" do
    belongs_to :server, HllConditionalActions.Servers.Server
    field :name, :string
    field :description, :string
    field :icon, :string, default: "hero-trophy"
    field :tier, Ecto.Enum, values: @tiers, default: :bronze
    field :scope, Ecto.Enum, values: [:match, :career], default: :match
    field :metric, Ecto.Enum, values: Metrics.all()
    field :threshold, :integer
    field :reward_vip_hours, :integer, default: 0
    field :reward_flag, :string
    field :announce, :boolean, default: true
    field :simulation, :boolean, default: false
    field :enabled, :boolean, default: true

    has_many :unlocks, HllConditionalActions.Progression.PlayerAchievement

    timestamps(type: :utc_datetime)
  end

  @doc "The tiers, lowest first."
  @spec tiers() :: [atom()]
  def tiers, do: @tiers

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(achievement, attrs) do
    achievement
    |> cast(attrs, [
      :server_id,
      :name,
      :description,
      :icon,
      :tier,
      :scope,
      :metric,
      :threshold,
      :reward_vip_hours,
      :reward_flag,
      :announce,
      :simulation,
      :enabled
    ])
    |> validate_required([:server_id, :name, :scope, :metric, :threshold, :tier])
    |> assoc_constraint(:server)
    |> validate_length(:name, max: 60)
    |> validate_length(:reward_flag, max: 8)
    |> validate_number(:threshold, greater_than: 0)
    |> validate_number(:reward_vip_hours, greater_than_or_equal_to: 0)
    |> validate_metric_scope()
  end

  # Some metrics only make sense over a career: you do not play "10 matches"
  # inside one match.
  defp validate_metric_scope(changeset) do
    scope = get_field(changeset, :scope)
    metric = get_field(changeset, :metric)

    if scope == :match and metric in Metrics.career_only(),
      do: add_error(changeset, :metric, "can only be counted over a career"),
      else: changeset
  end
end
