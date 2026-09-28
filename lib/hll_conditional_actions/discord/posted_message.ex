defmodule HllConditionalActions.Discord.PostedMessage do
  @moduledoc """
  A message or forum thread a rule keeps coming back to.

  An action in edit mode renders a key (by default one per rule and server)
  and edits the message stored under it instead of posting a new one. An
  action that opens a forum thread stores the thread under `"thread:" <> name`
  so later posts land in the same thread.
  """

  use Ecto.Schema

  alias HllConditionalActions.Discord.Webhook

  @type t :: %__MODULE__{}

  schema "discord_messages" do
    field :key, :string
    field :message_id, :string
    field :thread_id, :string

    belongs_to :webhook, Webhook

    timestamps(type: :utc_datetime)
  end
end
