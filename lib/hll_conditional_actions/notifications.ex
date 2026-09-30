defmodule HllConditionalActions.Notifications do
  @moduledoc """
  What the bell in the header lists: the open items of the attention inbox,
  tickets opened in the last day and the internal notes that mention the
  user, newest first, each read or unread for that user.

  Nothing here is stored but the read marks (`notification_reads`). The items
  come from what already exists, like `HllConditionalActions.Attention`, and
  every item carries a key that changes with each new occurrence (a rule
  failing again, a new ticket, another note), so something new always
  arrives unread.

  The attention items are passed in rather than read again: the navigation
  already computes them for its badges on every page.
  """

  import Ecto.Query

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Notifications.Read
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Tickets.Message
  alias HllConditionalActions.Tickets.Ticket

  @type item :: %{
          key: String.t(),
          kind: atom(),
          severity: :error | :warning | :info,
          at: DateTime.t() | nil,
          subject: map(),
          mention?: boolean(),
          unread?: boolean()
        }

  @new_ticket_hours 24
  @mention_days 7
  @limit 30

  @doc """
  Every notification of a user, unread first, then the most urgent and the
  newest. `attention` is the open list of `HllConditionalActions.Attention.items/3`
  for the same user and servers.
  """
  @spec list(map() | nil, [map()], [map()]) :: [item()]
  def list(nil, _servers, _attention), do: []

  def list(user, servers, attention) do
    server_ids = Enum.map(servers, & &1.id)
    waiting = for %{kind: :ticket_waiting, subject: %{ticket: t}} <- attention, do: t.id

    items =
      Enum.map(attention, &from_attention/1) ++
        new_tickets(user, server_ids, waiting) ++ mentions(user, server_ids)

    read = read_keys(user, Enum.map(items, & &1.key))

    items
    |> Enum.map(&%{&1 | unread?: not MapSet.member?(read, &1.key)})
    |> Enum.sort_by(&{not &1.unread?, severity(&1.severity), -unix(&1.at)})
    |> Enum.take(@limit)
  end

  @doc "How many notifications the user has not read, for the bell."
  @spec unread_count(map() | nil, [map()], [map()]) :: non_neg_integer()
  def unread_count(user, servers, attention),
    do: user |> list(servers, attention) |> Enum.count(& &1.unread?)

  @doc """
  Marks notifications as read by a user. Marking one twice is harmless.
  """
  @spec mark_read(map() | nil, [String.t()]) :: :ok
  def mark_read(nil, _keys), do: :ok
  def mark_read(_user, []), do: :ok

  def mark_read(user, keys) do
    now = DateTime.utc_now(:second)
    rows = for key <- Enum.uniq(keys), do: %{user_id: user.id, key: key, inserted_at: now}

    Repo.insert_all(Read, rows, on_conflict: :nothing, conflict_target: [:user_id, :key])
    prune(user)
    :ok
  end

  # Keys of items long gone are no use; a month of them is plenty.
  defp prune(user) do
    cutoff = DateTime.add(DateTime.utc_now(), -45, :day)
    Repo.delete_all(from r in Read, where: r.user_id == ^user.id and r.inserted_at < ^cutoff)
  end

  defp read_keys(_user, []), do: MapSet.new()

  defp read_keys(user, keys) do
    Read
    |> where([r], r.user_id == ^user.id and r.key in ^keys)
    |> select([r], r.key)
    |> Repo.all()
    |> MapSet.new()
  end

  # ── Sources ────────────────────────────────────────────────────────────────

  defp from_attention(item) do
    %{
      key: "attention:" <> item.key,
      kind: item.kind,
      severity: item.severity,
      at: item.at,
      subject: item.subject,
      mention?: false,
      unread?: true
    }
  end

  # Tickets opened in the last day; one that already waited too long is its
  # attention item instead.
  defp new_tickets(user, server_ids, waiting) do
    if Accounts.can?(user, :view_tickets) and server_ids != [] do
      since = DateTime.add(DateTime.utc_now(), -@new_ticket_hours, :hour)

      tickets =
        Ticket
        |> where([t], t.server_id in ^server_ids and t.status == :open)
        |> where([t], t.inserted_at >= ^since and t.id not in ^waiting)
        |> order_by([t], desc: t.inserted_at)
        |> limit(10)
        |> preload(:server)
        |> Repo.all()

      first = first_messages(Enum.map(tickets, & &1.id))

      Enum.map(tickets, fn ticket ->
        %{
          key: "ticket:#{ticket.id}",
          kind: :ticket_new,
          severity: :info,
          at: ticket.inserted_at,
          subject: %{ticket: ticket, message: first[ticket.id]},
          mention?: false,
          unread?: true
        }
      end)
    else
      []
    end
  end

  defp first_messages([]), do: %{}

  defp first_messages(ids) do
    Message
    |> where([m], m.ticket_id in ^ids and m.author == :player)
    |> order_by([m], asc: m.id)
    |> select([m], {m.ticket_id, m.body})
    |> Repo.all()
    |> Enum.reverse()
    |> Map.new()
  end

  # Internal notes by somebody else that name the user as @username or
  # @name (a first name is enough).
  defp mentions(user, server_ids) do
    handles = handles(user)

    if Accounts.can?(user, :view_tickets) and server_ids != [] and handles != [] do
      since = DateTime.add(DateTime.utc_now(), -@mention_days, :day)

      named =
        Enum.reduce(handles, dynamic(false), fn handle, acc ->
          pattern = "%@" <> handle <> "%"
          dynamic([m], ^acc or ilike(m.body, ^pattern))
        end)

      Message
      |> join(:inner, [m], t in assoc(m, :ticket))
      |> where([m, t], t.server_id in ^server_ids and m.author == :note)
      |> where([m], m.inserted_at >= ^since and m.user_id != ^user.id)
      |> where(^named)
      |> order_by([m], desc: m.inserted_at)
      |> limit(10)
      |> preload([:user, ticket: :server])
      |> Repo.all()
      |> Enum.map(fn message ->
        %{
          key: "mention:#{message.id}",
          kind: :mention,
          severity: :info,
          at: message.inserted_at,
          subject: %{message: message, ticket: message.ticket, handles: handles},
          mention?: true,
          unread?: true
        }
      end)
    else
      []
    end
  end

  @doc false
  @spec handles(map()) :: [String.t()]
  def handles(user) do
    first_name =
      case String.split(user.name || "", ~r/\s+/, trim: true) do
        [first | _rest] -> first
        [] -> nil
      end

    [user.username, first_name]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.map(&String.replace(&1, ~r/[%_\\]/, ""))
    |> Enum.reject(&(String.length(&1) < 2))
    |> Enum.uniq_by(&String.downcase/1)
  end

  defp severity(:error), do: 0
  defp severity(:warning), do: 1
  defp severity(_info), do: 2

  defp unix(nil), do: 0
  defp unix(%DateTime{} = at), do: DateTime.to_unix(at)

  defp unix(%NaiveDateTime{} = at),
    do: at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()
end
