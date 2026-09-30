defmodule HllConditionalActions.Engine.SavedEvents do
  @moduledoc """
  Recent real events, kept in Postgres so a rule can be tried, replayed and
  explained without a live server or a connected player.

  `HllConditionalActions.Engine.Samples` keeps its ring in memory and hands
  every new sample here in batches.

  ## Retention

  An event is kept for `retention_days/0` (7) days, and each
  `{server, trigger}` pair keeps at most its newest `keep/0` (2,000) of them.
  Together that makes the rule builder's "7-day replay" really cover a week
  on a quiet trigger (a connect, a match start), while a busy one (kills)
  stays bounded - a few MB per server - and covers its newest 2,000.

  Both prunes stay off the hot path:

    * the count cap is enforced on write, but only for pairs that may be
      over it (`store/2`'s `:prune`); `Samples` asks for it once a pair has
      gained `prune_slack/0` rows since it last did, so a pair holds at most
      `keep/0 + prune_slack/0` rows between two prunes. The delete walks the
      `(server_id, trigger, occurred_at)` index down to the newest `keep/0`
      and removes what is past it.
    * the age limit is one `DELETE` an hour from
      `HllConditionalActions.Workers.PruneSavedEvents`.

  The sample is stored as an Erlang term: it holds exactly what the evaluator
  reads, and round-trips without a schema of its own.
  """

  import Ecto.Query

  alias HllConditionalActions.Engine.SavedEvent
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Rules.Catalog

  @keep 2_000
  @retention_days 7
  @prune_slack 200

  @doc "At most how many events are kept per server and trigger."
  @spec keep() :: pos_integer()
  def keep, do: @keep

  @doc "How many days an event is kept."
  @spec retention_days() :: pos_integer()
  def retention_days, do: @retention_days

  @doc """
  How many rows a pair may gain past `keep/0` before a writer should prune
  it; see the moduledoc.
  """
  @spec prune_slack() :: pos_integer()
  def prune_slack, do: @prune_slack

  @doc """
  Stores samples.

  Option `:prune` - which `{server_id, trigger}` pairs to cut back to
  `keep/0` afterwards (`trigger` as an atom or a string): `:touched` (the
  default) prunes every pair in the batch, a list prunes those, `[]` none.
  """
  @spec store([map()], keyword()) :: :ok
  def store(samples, opts \\ [])

  def store([], _opts), do: :ok

  def store(samples, opts) when is_list(samples) do
    now = DateTime.utc_now()

    rows =
      Enum.map(samples, fn sample ->
        %{
          server_id: sample.server_id,
          trigger: to_string(sample.trigger),
          player_id: sample.player_id,
          player_name: sample.player_name && String.slice(sample.player_name, 0, 255),
          payload: :erlang.term_to_binary(sample, [:compressed]),
          occurred_at: sample.at,
          inserted_at: now
        }
      end)

    Repo.insert_all(SavedEvent, rows)

    pairs =
      case Keyword.get(opts, :prune, :touched) do
        :touched -> Enum.map(rows, &{&1.server_id, &1.trigger})
        pairs when is_list(pairs) -> pairs
      end

    pairs
    |> Enum.map(fn {server_id, trigger} -> {server_id, to_string(trigger)} end)
    |> Enum.uniq()
    |> Enum.each(fn {server_id, trigger} -> prune_count(server_id, trigger) end)
  end

  @doc """
  Cuts a `{server, trigger}` pair back to its newest `keep/0` events.
  Returns how many were deleted.
  """
  @spec prune_count(term(), atom() | String.t()) :: non_neg_integer()
  def prune_count(server_id, trigger) do
    trigger = to_string(trigger)

    # Everything past the newest `keep/0`: an index walk that stops early
    # (and finds nothing) while the pair is under the cap.
    beyond =
      from e in SavedEvent,
        where: e.server_id == ^server_id and e.trigger == ^trigger,
        order_by: [desc: e.occurred_at, desc: e.id],
        offset: @keep,
        select: e.id

    {deleted, _rows} = Repo.delete_all(from e in SavedEvent, where: e.id in subquery(beyond))
    deleted
  end

  @doc """
  Deletes every event older than `retention_days/0`, on every server.
  Returns how many were deleted.
  """
  @spec prune_old(DateTime.t()) :: non_neg_integer()
  def prune_old(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -@retention_days, :day)
    {deleted, _rows} = Repo.delete_all(from e in SavedEvent, where: e.occurred_at < ^cutoff)
    deleted
  end

  @doc """
  Saved events on some servers, newest first.

  Options: `:trigger`, `:player` (an id, or part of a name), `:from`, `:to`
  and `:limit` (default 100).
  """
  @spec list([term()], keyword()) :: [SavedEvent.t()]
  def list(server_ids, opts \\ []) do
    SavedEvent
    |> where([e], e.server_id in ^server_ids)
    |> filter(opts)
    |> order_by([e], desc: e.occurred_at, desc: e.id)
    |> limit(^Keyword.get(opts, :limit, 100))
    |> Repo.all()
    |> Enum.flat_map(&decode/1)
  end

  defp filter(query, opts) do
    Enum.reduce(opts, query, fn
      {:trigger, trigger}, query when not is_nil(trigger) ->
        where(query, [e], e.trigger == ^to_string(trigger))

      {:player, player}, query when is_binary(player) and player != "" ->
        pattern = "%" <> String.replace(player, ~r/[\\%_]/, "\\\\\\0") <> "%"
        where(query, [e], e.player_id == ^player or ilike(e.player_name, ^pattern))

      {:from, %DateTime{} = from}, query ->
        where(query, [e], e.occurred_at >= ^from)

      {:to, %DateTime{} = to}, query ->
        where(query, [e], e.occurred_at <= ^to)

      _other, query ->
        query
    end)
  end

  @doc "One saved event, when it belongs to one of these servers."
  @spec get([term()], term()) :: SavedEvent.t() | nil
  def get(server_ids, id) do
    with {id, ""} <- Integer.parse(to_string(id)),
         %SavedEvent{} = event <-
           Repo.one(from e in SavedEvent, where: e.id == ^id and e.server_id in ^server_ids),
         [decoded] <- decode(event) do
      decoded
    else
      _other -> nil
    end
  end

  @doc """
  The players seen in saved events, `{player_id, name}`, most recent first,
  for autocomplete.
  """
  @spec players([term()], non_neg_integer()) :: [{String.t(), String.t()}]
  def players(server_ids, limit \\ 200) do
    Repo.all(
      from e in SavedEvent,
        where: e.server_id in ^server_ids and not is_nil(e.player_id),
        group_by: e.player_id,
        order_by: [desc: max(e.occurred_at)],
        select: {e.player_id, max(e.player_name)},
        limit: ^limit
    )
  end

  @doc """
  The newest `per_pair` saved events of every `{server, trigger}` pair,
  oldest first, for warming the in-memory ring - which holds far fewer than
  the table, so only that many are read back.
  """
  @spec latest_samples(pos_integer()) :: [map()]
  def latest_samples(per_pair) do
    ranked =
      from e in SavedEvent,
        windows: [
          pair: [
            partition_by: [e.server_id, e.trigger],
            order_by: [desc: e.occurred_at, desc: e.id]
          ]
        ],
        select: %{id: e.id, rank: over(row_number(), :pair)}

    from(e in SavedEvent,
      join: r in subquery(ranked),
      on: r.id == e.id,
      where: r.rank <= ^per_pair,
      order_by: [asc: e.occurred_at, asc: e.id]
    )
    |> Repo.all()
    |> Enum.flat_map(&decode/1)
    |> Enum.map(& &1.sample)
  end

  # A payload written by an older build may name an atom this one does not
  # know; that row is skipped rather than crashing the page.
  defp decode(%SavedEvent{payload: payload} = event) do
    sample = :erlang.binary_to_term(payload, [:safe])
    trigger = Enum.find(Catalog.triggers(), &(to_string(&1) == event.trigger))
    [%{event | sample: %{sample | trigger: trigger}}]
  rescue
    ArgumentError -> []
  end
end
