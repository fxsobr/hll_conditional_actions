defmodule HllConditionalActions.Tickets.Reported do
  @moduledoc """
  Who a ticket is about - the player being reported, shown as "Citado" in
  the Caixa - worked out once when the ticket opens:

    1. the player who team killed the caller the most in the minutes before
       the call (the captured context), the latest one on a tie;
    2. otherwise a name the caller wrote that matches exactly one player
       seen on the server in those minutes ("é o Rudi" finds `Rudi_88`).

  Nobody is picked when neither says anything for sure; an admin can set or
  change it on the ticket.
  """

  import Ecto.Query

  alias HllConditionalActions.Crcon.Events.Event
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Rules.Execution
  alias HllConditionalActions.Tickets.Context
  alias HllConditionalActions.Tickets.Ticket

  @type player :: %{id: String.t(), name: String.t()}

  # Words shorter than this are too common to mean a name.
  @min_word 4

  @doc """
  The reported player, or nil.

      iex> alias HllConditionalActions.Tickets.Reported
      iex> alias HllConditionalActions.Crcon.Events.Event
      iex> call = %Event{type: :player_chat, action: "CHAT", occurred_at: nil, player_id: "p1", player_name: "Kowalski"}
      iex> context = [
      ...>   %{"kind" => "team_kill", "actor" => "Rudi_88", "actor_id" => "p9", "target_id" => "p1"},
      ...>   %{"kind" => "team_kill", "actor" => "Lima", "actor_id" => "p5", "target_id" => "p7"}
      ...> ]
      iex> Reported.detect(context, call, "help", [])
      %{id: "p9", name: "Rudi_88"}
      iex> seen = [%Event{type: :player_chat, action: "CHAT", occurred_at: nil, player_id: "p9", player_name: "Rudi_88"}]
      iex> Reported.detect([], call, "é o rudi, já matou 3", seen)
      %{id: "p9", name: "Rudi_88"}
      iex> Reported.detect([], call, "someone is team killing", seen)
      nil
  """
  @spec detect([map()], Event.t(), String.t(), [Event.t()]) :: player() | nil
  def detect(context, %Event{} = call, text, recent) do
    team_killer(context, call.player_id) || named(text, call.player_id, known(context, recent))
  end

  defp team_killer(context, caller) do
    context
    |> Enum.with_index()
    |> Enum.filter(fn {line, _index} ->
      line["kind"] == "team_kill" and line["target_id"] == caller and
        present?(line["actor_id"]) and line["actor_id"] != caller
    end)
    |> Enum.group_by(fn {line, _index} -> line["actor_id"] end)
    |> Enum.max_by(
      fn {_id, lines} -> {length(lines), lines |> Enum.map(&elem(&1, 1)) |> Enum.max()} end,
      fn -> nil end
    )
    |> case do
      nil ->
        nil

      {id, [{line, _index} | _rest]} ->
        %{id: id, name: line["actor"] || id}
    end
  end

  # Everyone the context or the recent events name, by id.
  defp known(context, recent) do
    from_context =
      Enum.flat_map(context, fn line ->
        [{line["actor_id"], line["actor"]}, {line["target_id"], line["target"]}]
      end)

    from_events =
      Enum.flat_map(recent, fn
        %Event{} = event ->
          [
            {event.player_id, event.player_name},
            {event.target_player_id, event.target_player_name}
          ]

        _other ->
          []
      end)

    (from_context ++ from_events)
    |> Enum.filter(fn {id, name} -> present?(id) and present?(name) end)
    |> Map.new()
  end

  defp named(text, caller, known) do
    words =
      (text || "")
      |> String.downcase()
      |> String.split(~r/[^\p{L}\p{N}_\-\[\]]+/u, trim: true)
      |> Enum.filter(&(String.length(&1) >= @min_word))

    matches =
      known
      |> Map.delete(caller)
      |> Enum.filter(fn {_id, name} ->
        name = String.downcase(name)
        Enum.any?(words, &(name == &1 or String.starts_with?(name, &1)))
      end)

    case matches do
      [{id, name}] -> %{id: id, name: name}
      _none_or_many -> nil
    end
  end

  @doc """
  The reported player of a ticket opened before names and ids were kept on
  its context: the same two rules, by name, with the id found among the
  players the app has seen (their tickets and the rule runs about them).
  Nil when nothing is sure.
  """
  @spec infer(map()) :: player() | nil
  def infer(%{context: context, player_id: caller_id} = ticket) do
    lines = Enum.map(context || [], &Context.normalize/1)
    caller = ticket.player_name

    text =
      ticket
      |> Map.get(:messages, [])
      |> Enum.find_value("", fn message -> message.author == :player && message.body end)

    name =
      team_killer_by_name(lines, caller) ||
        lines
        |> Enum.flat_map(&[&1["actor"], &1["target"]])
        |> Enum.filter(&present?/1)
        |> Enum.reject(&(&1 == caller))
        |> Enum.uniq()
        |> Map.new(&{&1, &1})
        |> then(&named(text, nil, &1))
        |> then(&(&1 && &1.name))

    with name when is_binary(name) <- name,
         id when is_binary(id) and id != caller_id <- id_for(name) do
      %{id: id, name: name}
    else
      _unsure -> nil
    end
  end

  defp team_killer_by_name(lines, caller) do
    lines
    |> Enum.filter(
      &(&1["kind"] == "team_kill" and &1["target"] == caller and present?(&1["actor"]))
    )
    |> Enum.frequencies_by(& &1["actor"])
    |> Enum.max_by(fn {_name, count} -> count end, fn -> nil end)
    |> case do
      nil -> nil
      {name, _count} -> name
    end
  end

  # The id of the player last seen under a name.
  defp id_for(name) do
    Repo.one(
      from t in Ticket,
        where: t.player_name == ^name or t.reported_player_name == ^name,
        order_by: [desc: t.inserted_at],
        limit: 1,
        select:
          fragment(
            "CASE WHEN ? = ? THEN ? ELSE ? END",
            t.player_name,
            ^name,
            t.player_id,
            t.reported_player_id
          )
    ) ||
      Repo.one(
        from e in Execution,
          where: e.player_name == ^name and not is_nil(e.player_id),
          order_by: [desc: e.executed_at],
          limit: 1,
          select: e.player_id
      )
  end

  defp present?(value), do: is_binary(value) and value != ""
end
