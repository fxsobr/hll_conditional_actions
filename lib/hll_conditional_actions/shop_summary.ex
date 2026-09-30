defmodule HllConditionalActions.ShopSummary do
  @moduledoc """
  The one line about the VIP shop the phone's "Mais" sheet shows: how many
  orders were paid today and for how much, and how many paid orders still
  wait for their VIP to be delivered.

  Test purchases are left out, like on the purchases page.
  """

  import Ecto.Query

  alias HllConditionalActions.Repo
  alias HllConditionalActions.VipShop.Order

  @paid ~w(paid fulfilled partial failed)

  @doc """
  Today's paid orders (from midnight UTC), their revenue per currency, and
  the orders paid but not yet delivered.
  """
  @spec today(DateTime.t()) :: %{
          paid: non_neg_integer(),
          revenue: [{String.t(), integer()}],
          pending: non_neg_integer()
        }
  def today(now \\ DateTime.utc_now()) do
    midnight = DateTime.new!(DateTime.to_date(now), ~T[00:00:00], "Etc/UTC")

    paid_today =
      from o in Order,
        where: o.status in @paid and not o.test and o.paid_at >= ^midnight

    revenue =
      paid_today
      |> group_by([o], o.currency)
      |> select([o], {o.currency, sum(o.amount_cents)})
      |> Repo.all()

    %{
      paid: Repo.aggregate(paid_today, :count),
      revenue: revenue,
      pending: Repo.aggregate(from(o in Order, where: o.status == "paid" and not o.test), :count)
    }
  end
end
