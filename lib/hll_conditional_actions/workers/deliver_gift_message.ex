defmodule HllConditionalActions.Workers.DeliverGiftMessage do
  @moduledoc """
  Shows the buyer's message to the player who got the VIP, in the game.

  Queued at checkout with the order. It waits for the payment and the
  delivery, then sends the message on the first server that took the VIP
  and has the player online. A player who is not playing is tried again
  every few minutes for a day; a canceled order drops the message.
  """

  use Oban.Worker, queue: :shop, max_attempts: 300, unique: [period: 60, keys: [:order_id]]
  use Gettext, backend: HllConditionalActionsWeb.Gettext

  alias HllConditionalActions.Crcon
  alias HllConditionalActions.Servers
  alias HllConditionalActions.VipShop
  alias HllConditionalActions.VipShop.Storefront

  # Try for a day: waiting for the payment, then for the player to be online.
  @give_up_after 24 * 60 * 60
  @retry_in 5 * 60

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"order_id" => id}, inserted_at: queued_at}) do
    with %{} = order <- VipShop.get_order(id),
         %{delivered_at: nil} = note <- Storefront.order_note(id) do
      deliver(order, note, queued_at)
    else
      _nothing_to_do -> :ok
    end
  end

  defp deliver(%{status: "canceled"}, _note, _queued_at), do: {:cancel, "order canceled"}

  defp deliver(order, note, queued_at) do
    servers =
      for grant <- order.grants,
          grant.status == "granted",
          grant.server_id,
          {:ok, server} <- [Servers.fetch_server(grant.server_id)],
          do: server

    sent = Enum.find(servers, &sent?(&1, order, note))

    cond do
      sent ->
        {:ok, _note} = Storefront.mark_note_delivered(note, sent.name)
        :ok

      DateTime.diff(DateTime.utc_now(), queued_at || DateTime.utc_now()) > @give_up_after ->
        {:cancel, "the player was not online in a day"}

      true ->
        {:snooze, @retry_in}
    end
  end

  defp sent?(server, order, note) do
    text =
      gettext("A gift: %{package}.", package: order.package_name) <> " \"" <> note.message <> "\""

    match?({:ok, _result}, Crcon.message_player(server, order.player_id, text))
  rescue
    _error -> false
  end
end
