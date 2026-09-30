defmodule HllConditionalActions.Tickets.Ticket do
  @moduledoc """
  A player's call for an admin on one server, and the conversation that
  follows.

  Status tells whose turn it is: `:open` waits on an admin, `:answered` waits
  on the player, `:closed` is done. A player writing again moves the ticket
  back to `:open`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @statuses [:open, :answered, :closed]
  # Lowest first; `rank/1` gives each its weight for sorting.
  @priorities [:low, :normal, :high, :urgent]

  schema "tickets" do
    belongs_to :server, HllConditionalActions.Servers.Server
    belongs_to :assigned_to, HllConditionalActions.Accounts.User
    belongs_to :closed_by, HllConditionalActions.Accounts.User
    belongs_to :rule, HllConditionalActions.Rules.Rule

    field :player_id, :string
    field :player_name, :string
    field :status, Ecto.Enum, values: @statuses, default: :open
    field :priority, Ecto.Enum, values: @priorities, default: :normal
    field :close_reason, :string
    field :last_activity_at, :utc_datetime
    field :closed_at, :utc_datetime
    field :first_response_at, :utc_datetime
    field :source, Ecto.Enum, values: [:chat, :rule], default: :chat
    field :category, :string
    field :context, {:array, :map}, default: []
    # The chat command the player typed, for "opened with !admin".
    field :opened_with, :string
    # The other player the ticket is about - the one being reported.
    field :reported_player_id, :string
    field :reported_player_name, :string
    field :announced_at, :utc_datetime
    field :close_warned_at, :utc_datetime
    field :outside_hours, :boolean, default: false

    has_many :messages, HllConditionalActions.Tickets.Message,
      preload_order: [asc: :inserted_at, asc: :id]

    timestamps(type: :utc_datetime)
  end

  @doc "Every status, in display order."
  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @doc """
  How much a priority weighs, for sorting and for "raise, never lower".

      iex> alias HllConditionalActions.Tickets.Ticket
      iex> Enum.map(Ticket.priorities(), &Ticket.rank/1)
      [0, 1, 2, 3]
  """
  @spec rank(atom()) :: non_neg_integer()
  def rank(priority), do: Enum.find_index(@priorities, &(&1 == priority)) || 1

  @doc """
  A priority from a string, falling back to `:normal` for anything unknown.

      iex> HllConditionalActions.Tickets.Ticket.parse_priority("high")
      :high
      iex> HllConditionalActions.Tickets.Ticket.parse_priority("panic")
      :normal
  """
  @spec parse_priority(term()) :: atom()
  def parse_priority(priority) when is_atom(priority) and priority in @priorities, do: priority

  def parse_priority(priority) when is_binary(priority),
    do: Enum.find(@priorities, :normal, &(to_string(&1) == priority))

  def parse_priority(_priority), do: :normal

  @doc "Every priority, in display order."
  @spec priorities() :: [atom()]
  def priorities, do: @priorities

  @doc false
  @spec open_changeset(t(), map()) :: Ecto.Changeset.t()
  def open_changeset(ticket, attrs) do
    ticket
    |> cast(attrs, [
      :server_id,
      :player_id,
      :player_name,
      :priority,
      :last_activity_at,
      :source,
      :rule_id,
      :category,
      :context,
      :opened_with,
      :reported_player_id,
      :reported_player_name,
      :outside_hours
    ])
    |> validate_required([:server_id, :player_id, :last_activity_at])
  end

  @doc false
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(ticket, attrs) do
    ticket
    |> cast(attrs, [
      :player_name,
      :status,
      :priority,
      :assigned_to_id,
      :closed_by_id,
      :close_reason,
      :last_activity_at,
      :closed_at,
      :first_response_at,
      :category,
      :reported_player_id,
      :reported_player_name,
      :announced_at,
      :close_warned_at
    ])
    |> validate_length(:close_reason, max: 255)
  end
end
