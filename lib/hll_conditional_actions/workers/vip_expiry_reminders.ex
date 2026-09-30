defmodule HllConditionalActions.Workers.VipExpiryReminders do
  @moduledoc """
  Once a day, emails customers whose VIP ends within the shop's reminder
  window, with a link to renew. Each grant is reminded once.
  """

  use Oban.Worker, queue: :shop, max_attempts: 3

  alias HllConditionalActions.VipShop

  @impl Oban.Worker
  def perform(_job) do
    if VipShop.open?() do
      VipShop.send_expiry_reminders(HllConditionalActionsWeb.Endpoint.url() <> "/shop")
    end

    :ok
  end
end
