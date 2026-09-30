defmodule HllConditionalActions.Workers.FulfillVipOrder do
  @moduledoc """
  Grants a paid order's VIP on every server of its package.

  Queued so the payment webhook answers the provider at once, and retried:
  a CRCON that is briefly down leaves the order `failed` or `partial`, and
  the next attempt only retries the servers that did not take it.
  """

  use Oban.Worker, queue: :shop, max_attempts: 5, unique: [period: 60, keys: [:order_id]]

  alias HllConditionalActions.VipShop

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"order_id" => id}}) do
    case VipShop.get_order(id) do
      nil ->
        {:cancel, "order #{id} no longer exists"}

      %{status: status} = order when status in ~w(paid partial failed) ->
        {:ok, order} = VipShop.fulfill(order)

        if order.status in ~w(partial failed),
          do: {:error, "VIP not granted on every server"},
          else: :ok

      _done ->
        :ok
    end
  end
end
