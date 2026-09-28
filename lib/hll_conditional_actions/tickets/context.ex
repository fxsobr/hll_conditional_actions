defmodule HllConditionalActions.Tickets.Context do
  @moduledoc """
  What happened around a player before they called an admin, captured once
  when the ticket opens: the last lines of chat on the server, and the kills,
  deaths and team kills the player was part of.

  `HllConditionalActions.Tickets.Listener` keeps a short rolling window of
  the server's events and hands it over; this module picks the relevant
  lines out of it. The result is stored on the ticket as plain maps, so it
  reads the same after the window has long moved on.
  """

  alias HllConditionalActions.Crcon.Events.Event

  # How far back the window reaches, and how much of it is kept.
  @window_seconds 300
  @max_chat 10
  @max_combat 15

  @kept [:player_chat, :player_kill, :player_team_kill]

  @doc "How long the listener should keep events around."
  @spec window_seconds() :: pos_integer()
  def window_seconds, do: @window_seconds

  @doc "Whether an event is worth keeping in the rolling window."
  @spec keep?(Event.t()) :: boolean()
  def keep?(%Event{type: type}), do: type in @kept

  @doc """
  The context of a call, oldest line first.

      iex> alias HllConditionalActions.Tickets.Context
      iex> alias HllConditionalActions.Crcon.Events.Event
      iex> at = ~U[2026-09-26 20:00:00Z]
      iex> call = %Event{type: :player_chat, action: "CHAT", occurred_at: at, player_id: "p1", player_name: "Sarge", chat_message: "!admin tk"}
      iex> tk = %Event{type: :player_team_kill, action: "TEAM KILL", occurred_at: ~U[2026-09-26 19:59:00Z],
      ...>   player_id: "p2", player_name: "Rambo", target_player_id: "p1", target_player_name: "Sarge", weapon: "M1 GARAND"}
      iex> Context.capture([tk, call], call)
      [%{"at" => "2026-09-26T19:59:00Z", "kind" => "team_kill", "text" => "Rambo team killed Sarge (M1 GARAND)"}]
  """
  @spec capture([Event.t()], Event.t()) :: [map()]
  def capture(_recent, %Event{occurred_at: nil}), do: []

  def capture(recent, %Event{} = call) do
    since = DateTime.add(call.occurred_at, -@window_seconds, :second)

    relevant =
      Enum.filter(recent, fn event ->
        event != call and match?(%DateTime{}, event.occurred_at) and
          DateTime.compare(event.occurred_at, since) != :lt and
          DateTime.compare(event.occurred_at, call.occurred_at) != :gt
      end)

    chat =
      relevant
      |> Enum.filter(&(&1.type == :player_chat))
      |> Enum.take(-@max_chat)

    combat =
      relevant
      |> Enum.filter(
        &(&1.type in [:player_kill, :player_team_kill] and involves?(&1, call.player_id))
      )
      |> Enum.take(-@max_combat)

    (chat ++ combat)
    |> Enum.sort_by(& &1.occurred_at, DateTime)
    |> Enum.map(&line/1)
  end

  defp involves?(event, player_id),
    do: event.player_id == player_id or event.target_player_id == player_id

  defp line(%Event{type: :player_chat} = event) do
    scope = if event.chat_scope, do: " [#{event.chat_scope}]", else: ""
    entry(event, "chat", "#{event.player_name}#{scope}: #{event.chat_message}")
  end

  defp line(%Event{type: :player_team_kill} = event),
    do:
      entry(
        event,
        "team_kill",
        "#{event.player_name} team killed #{event.target_player_name}#{weapon(event)}"
      )

  defp line(%Event{type: :player_kill} = event),
    do:
      entry(
        event,
        "kill",
        "#{event.player_name} killed #{event.target_player_name}#{weapon(event)}"
      )

  defp entry(event, kind, text),
    do: %{"at" => DateTime.to_iso8601(event.occurred_at), "kind" => kind, "text" => text}

  defp weapon(%Event{weapon: weapon}) when is_binary(weapon) and weapon != "", do: " (#{weapon})"
  defp weapon(_event), do: ""
end
