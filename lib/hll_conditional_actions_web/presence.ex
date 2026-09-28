defmodule HllConditionalActionsWeb.Presence do
  @moduledoc """
  Who has a ticket open right now, and whether they are typing an answer.

  Two volunteers answering the same player at once is the classic help desk
  mistake; the ticket page shows the other admins on it ("Ana is viewing",
  "Ana is typing") the way Help Scout and Freshdesk do. Tracked per ticket
  on `"ticket_presence:<id>"`.
  """

  use Phoenix.Presence,
    otp_app: :hll_conditional_actions,
    pubsub_server: HllConditionalActions.PubSub

  @doc "The presence topic of a ticket."
  @spec ticket_topic(term()) :: String.t()
  def ticket_topic(ticket_id), do: "ticket_presence:#{ticket_id}"

  @doc """
  The other admins on a ticket: `[%{id, name, typing?}]`, typing first.
  """
  @spec others(term(), term()) :: [map()]
  def others(ticket_id, user_id) do
    ticket_id
    |> ticket_topic()
    |> list()
    |> Enum.reject(fn {id, _presence} -> id == to_string(user_id) end)
    |> Enum.map(fn {id, %{metas: metas}} ->
      %{
        id: id,
        name: metas |> List.first() |> Map.get(:name),
        typing?: Enum.any?(metas, & &1.typing)
      }
    end)
    |> Enum.sort_by(&{!&1.typing?, &1.name})
  end
end
