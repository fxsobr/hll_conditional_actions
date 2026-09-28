defmodule HllConditionalActions.Tickets.Message do
  @moduledoc """
  One line of a ticket's conversation.

  `author` is who wrote it: the player in game, an admin from the web, or the
  system (the automatic "received" and "closed" notices). Lines that go to the
  player record whether CRCON accepted them in `delivery`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "ticket_messages" do
    belongs_to :ticket, HllConditionalActions.Tickets.Ticket
    belongs_to :user, HllConditionalActions.Accounts.User

    # A :note is an admin's internal remark: stored, never sent to the player.
    field :author, Ecto.Enum, values: [:player, :admin, :system, :note]
    field :body, :string
    field :delivery, Ecto.Enum, values: [:sent, :failed]
    field :delivery_error, :string
    field :log_key, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(message, attrs) do
    message
    |> cast(attrs, [:ticket_id, :author, :user_id, :body, :delivery, :delivery_error, :log_key])
    |> validate_required([:ticket_id, :author, :body])
    |> validate_length(:body, max: 2000)
    |> update_change(:delivery_error, &String.slice(&1, 0, 255))
    |> unique_constraint([:ticket_id, :log_key], name: :ticket_messages_once_per_log_line)
  end
end
