defmodule HllConditionalActions.VipShop.CustomerToken do
  @moduledoc """
  A one-time token emailed to a customer, such as a password reset link.

  Only a SHA-256 hash of the token is stored, so a leaked database cannot be
  turned into working links; the plain token only ever exists in the email.
  Reset tokens are valid for 30 minutes and are deleted once used.
  """

  use Ecto.Schema

  import Ecto.Query

  @reset_validity_minutes 30

  schema "vip_customer_tokens" do
    field :token_hash, :binary
    field :context, :string

    belongs_to :customer, HllConditionalActions.VipShop.Customer

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  A new token for a customer: the plain token for the link, and the row to
  store.
  """
  @spec build(term(), String.t()) :: {String.t(), %__MODULE__{}}
  def build(customer_id, context) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    {token, %__MODULE__{customer_id: customer_id, context: context, token_hash: hash(token)}}
  end

  @doc "How long a password reset link works, in minutes."
  @spec reset_validity_minutes() :: pos_integer()
  def reset_validity_minutes, do: @reset_validity_minutes

  @doc "The query for a still valid token of a context."
  @spec valid_query(String.t(), String.t()) :: Ecto.Query.t()
  def valid_query(token, "reset") do
    since = DateTime.add(DateTime.utc_now(), -@reset_validity_minutes * 60, :second)

    from t in __MODULE__,
      where: t.token_hash == ^hash(token) and t.context == "reset" and t.inserted_at > ^since
  end

  defp hash(token), do: :crypto.hash(:sha256, token)
end
