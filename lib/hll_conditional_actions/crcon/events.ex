defmodule HllConditionalActions.Crcon.Events do
  @moduledoc """
  Normalizes CRCON's structured log lines into domain events.

  CRCON parses the game server's raw log lines into a
  `StructuredLogLineWithMetaData` map (see `Rcon.parse_log_line` in
  `rcon/rcon.py`) and pushes it over the log stream. The shape is stable across
  both games:

      %{
        "action" => "KILL" | "CHAT[Allies][Unit]" | "MATCH START" | ...,
        "player_name_1" => "Chris", "player_id_1" => "7656119…",
        "player_name_2" => "Muctar", "player_id_2" => "7656119…",
        "weapon" => "M1 GARAND", "message" => "...", "sub_content" => "...",
        "timestamp_ms" => 1699…, "raw" => "..."
      }

  Player 1 is always the actor and player 2 the target, which is what lets a
  single `KILL` line trigger both a kill rule for the killer and a death rule
  for the victim - see `triggers/1`.
  """

  alias HllConditionalActions.Crcon.Events.Event
  alias HllConditionalActions.Engine.Context

  # "CHAT[Allies][Unit]" -> team "allies", scope "unit". A player writing in the
  # all-chat produces "CHAT[Allies]" with no scope segment.
  @chat_regex ~r/^CHAT\[(?<team>[^\]]+)\](?:\[(?<scope>[^\]]+)\])?$/

  @doc """
  Builds an `Event` from a raw CRCON log map.

  `server` is used only to stamp the event with its origin; pass `nil` when
  normalizing a log line outside of a stream.
  """
  @spec from_log(map(), map() | nil) :: Event.t()
  def from_log(log, server \\ nil) when is_map(log) do
    action = to_string(log["action"] || "UNKNOWN")

    %Event{
      server_id: server && server.id,
      game: server && Map.get(server, :game),
      type: classify(action),
      action: action,
      player_id: blank_to_nil(log["player_id_1"]),
      player_name: blank_to_nil(log["player_name_1"]),
      target_player_id: blank_to_nil(log["player_id_2"]),
      target_player_name: blank_to_nil(log["player_name_2"]),
      weapon: blank_to_nil(log["weapon"]),
      message: blank_to_nil(log["message"]),
      chat_message: chat_message(action, log),
      chat_team: chat_part(action, "team"),
      chat_scope: chat_part(action, "scope"),
      occurred_at: occurred_at(log),
      raw: log
    }
  end

  @doc """
  Classifies a CRCON action string into an event type.

      iex> alias HllConditionalActions.Crcon.Events
      iex> {Events.classify("KILL"), Events.classify("CHAT[Axis][Team]")}
      {:player_kill, :player_chat}

      iex> HllConditionalActions.Crcon.Events.classify("MATCH ENDED")
      :match_end
  """
  @spec classify(String.t()) :: Event.type()
  def classify("CONNECTED"), do: :player_connected
  def classify("DISCONNECTED"), do: :player_disconnected
  def classify("TEAM KILL"), do: :player_team_kill
  def classify("KILL"), do: :player_kill
  def classify("TEAMSWITCH"), do: :team_switch
  def classify("MATCH START"), do: :match_start
  def classify("MATCH ENDED"), do: :match_end
  def classify("CAMERA"), do: :camera
  def classify("CHAT" <> _rest), do: :player_chat
  def classify("VOTE" <> _rest), do: :vote
  def classify("ADMIN" <> _rest), do: :admin_action
  def classify("TK" <> _rest), do: :admin_action
  def classify(_action), do: :unknown

  @doc """
  Expands an event into the per-player rule triggers it fires.

  A `KILL` line is the interesting case: it triggers `:player_kill` for the
  killer and `:player_death` for the victim, exactly like CRCON's own
  `conditional_actions_on_kill` hook does.

  Match-wide events return `[]` because they are evaluated against every
  connected player rather than a single one; see
  `HllConditionalActions.Engine.Runner`.
  """
  @spec triggers(Event.t()) :: [{atom(), String.t(), String.t() | nil}]
  def triggers(%Event{type: :player_kill} = event) do
    List.flatten([
      trigger(:player_kill, event.player_id, event.player_name),
      trigger(:player_death, event.target_player_id, event.target_player_name)
    ])
  end

  # A chat line that opens with a command prefix fires both triggers: rules
  # written against `player_chat` still see it (it *is* chat), and rules
  # written against `chat_command` get the parsed command without having to
  # pattern match the raw message.
  def triggers(%Event{type: :player_chat} = event) do
    command =
      if Context.command?(event.chat_message),
        do: trigger(:chat_command, event.player_id, event.player_name),
        else: []

    List.flatten([trigger(:player_chat, event.player_id, event.player_name), command])
  end

  def triggers(%Event{type: type} = event)
      when type in [
             :player_connected,
             :player_disconnected,
             :player_team_kill,
             :team_switch
           ] do
    trigger(type, event.player_id, event.player_name)
  end

  def triggers(%Event{}), do: []

  @doc """
  Whether an event is one the rule engine can act on.
  """
  @spec actionable?(Event.t()) :: boolean()
  def actionable?(%Event{} = event) do
    event.type in [:match_start, :match_end] or triggers(event) != []
  end

  defp trigger(_type, nil, _name), do: []
  defp trigger(type, player_id, player_name), do: [{type, player_id, player_name}]

  defp chat_message(action, log) do
    if String.starts_with?(action, "CHAT"), do: blank_to_nil(log["sub_content"])
  end

  defp chat_part(action, key) do
    case Regex.named_captures(@chat_regex, action) do
      %{^key => value} when value != "" -> String.downcase(value)
      _other -> nil
    end
  end

  # CRCON stamps every line with the game server's timestamp in milliseconds.
  defp occurred_at(%{"timestamp_ms" => ms}) when is_integer(ms) and ms > 0 do
    DateTime.from_unix!(ms, :millisecond)
  end

  defp occurred_at(_log), do: DateTime.utc_now()

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value) when is_binary(value), do: value
  defp blank_to_nil(value), do: to_string(value)
end
