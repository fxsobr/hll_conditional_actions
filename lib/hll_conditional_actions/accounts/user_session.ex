defmodule HllConditionalActions.Accounts.UserSession do
  @moduledoc """
  A browser someone is signed in on.

  The session cookie carries a random token; this row keeps only its SHA-256
  hash, the browser's user agent and address as they were at sign in, and when
  the browser was last seen. Deleting the row signs that browser out.
  """

  use Ecto.Schema

  alias HllConditionalActions.Accounts.User

  @type t :: %__MODULE__{}

  schema "user_sessions" do
    field :token_hash, :binary, redact: true
    field :user_agent, :string
    field :ip, :string
    field :last_seen_at, :utc_datetime

    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end
end
