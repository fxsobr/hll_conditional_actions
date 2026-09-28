defmodule HllConditionalActions.Engine.SavedEvents do
  @moduledoc """
  Recent real events, kept in Postgres so a rule can be tried, replayed and
  explained without a live server or a connected player.

  `HllConditionalActions.Engine.Samples` keeps its ring in memory and hands
  every new sample here in batches. Each `{server, trigger}` pair keeps only
  its latest `keep/0` events - older ones are pruned on every write - so the
  table stays small however busy a server is.

  The sample is stored as an Erlang term: it holds exactly what the evaluator
  reads, and round-trips without a schema of its own.
  """

  import Ecto.Query

  alias HllConditionalActions.Engine.SavedEvent
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Rules.Catalog

  @keep 50

  @doc "How many events are kept per server and trigger."
  @spec keep() :: pos_integer()
  def keep, do: @keep

  @doc """
  Stores samples and prunes each touched `{server, trigger}` back to `keep/0`.
  """
  @spec store([map()]) :: :ok
  def store([]), do: :ok

  def store(samples) when is_list(samples) do
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

    rows
    |> Enum.map(&{&1.server_id, &1.trigger})
    |> Enum.uniq()
    |> Enum.each(fn {server_id, trigger} -> prune(server_id, trigger) end)
  end

  defp prune(server_id, trigger) do
    kept =
      from e in SavedEvent,
        where: e.server_id == ^server_id and e.trigger == ^trigger,
        order_by: [desc: e.occurred_at, desc: e.id],
        limit: @keep,
        select: e.id

    Repo.delete_all(
      from e in SavedEvent,
        where: e.server_id == ^server_id and e.trigger == ^trigger and e.id not in subquery(kept)
    )

    :ok
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

  @doc "Every saved event, oldest first, for warming the in-memory ring."
  @spec all_samples() :: [map()]
  def all_samples do
    SavedEvent
    |> order_by([e], asc: e.occurred_at, asc: e.id)
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
