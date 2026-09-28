defmodule HllConditionalActionsWeb.EventEditor do
  @moduledoc """
  Turns an event sample (the map `HllConditionalActions.Engine.Samples` and
  `HllConditionalActions.Engine.SavedEvents` keep) into a small editable form,
  and applies the edits back.

  Only plain values are editable: the player's name and stats, and the event
  fields a rule can read (weapon, victim, chat text). Numbers stay numbers and
  yes/no stays boolean, judged by the value being replaced, so an edited
  sample evaluates exactly like a real one.
  """

  alias HllConditionalActions.Crcon.Events.Event
  alias HllConditionalActions.Engine.Samples

  @player_keys ~w(name level team role unit_name clan_tag is_vip kills deaths team_kills combat offense defense support map_playtime_seconds)
  @event_keys [:target_player_name, :weapon, :chat_message, :message]

  # Triggers whose conditions read an event, and the event type that carries them.
  @event_types %{
    player_kill: :player_kill,
    player_death: :player_kill,
    player_team_kill: :player_team_kill,
    player_chat: :player_chat,
    chat_command: :player_chat,
    team_switch: :team_switch,
    player_connected: :player_connected,
    player_disconnected: :player_disconnected
  }

  @doc """
  A made-up sample for a trigger, for composing an event from scratch.
  """
  @spec blank_sample(term(), atom()) :: map()
  def blank_sample(server_id, trigger) do
    player = %{
      "player_id" => "76561198000000000",
      "name" => "Ana",
      "team" => "allies",
      "role" => "rifleman",
      "unit_name" => "able",
      "level" => 42,
      "is_vip" => false,
      "kills" => 12,
      "deaths" => 4,
      "team_kills" => 0,
      "combat" => 180,
      "offense" => 90,
      "defense" => 60,
      "support" => 120
    }

    event =
      case Map.fetch(@event_types, trigger) do
        {:ok, type} ->
          %Event{
            type: type,
            action: "",
            player_id: player["player_id"],
            player_name: player["name"],
            target_player_name: if(type in [:player_kill, :player_team_kill], do: "Bruno"),
            weapon: if(type in [:player_kill, :player_team_kill], do: "M1 GARAND"),
            chat_message:
              if(type == :player_chat,
                do: if(trigger == :chat_command, do: "!discord", else: "hello")
              ),
            occurred_at: DateTime.utc_now()
          }

        :error ->
          nil
      end

    %{
      server_id: server_id,
      trigger: trigger,
      player_id: player["player_id"],
      player_name: player["name"],
      player: player,
      player_profile: nil,
      gamestate: nil,
      squad: %{},
      ranks: %{},
      event: event,
      at: DateTime.utc_now(),
      at_us: System.os_time(:microsecond)
    }
  end

  @doc """
  A sample of a player connected right now, from a CRCON snapshot.
  """
  @spec live_sample(term(), atom(), map(), map() | nil) :: map()
  def live_sample(server_id, trigger, player, gamestate) do
    %{
      blank_sample(server_id, trigger)
      | player_id: player["player_id"],
        player_name: player["name"],
        player: player,
        player_profile: player["profile"],
        gamestate: gamestate
    }
    |> Map.update!(:event, fn
      %Event{} = event -> %{event | player_id: player["player_id"], player_name: player["name"]}
      nil -> nil
    end)
  end

  @doc """
  The editable fields of a sample: `{name, key, value}` where `name` is the
  form input name.
  """
  @spec fields(map()) :: [{String.t(), String.t(), term()}]
  def fields(sample) do
    player = sample.player || %{}

    player_fields =
      for key <- @player_keys, Map.has_key?(player, key), do: {"player[#{key}]", key, player[key]}

    event_fields =
      case sample.event do
        %Event{} = event ->
          for key <- @event_keys,
              value = Map.get(event, key),
              not is_nil(value) or relevant?(event, key),
              do: {"event[#{key}]", to_string(key), value}

        _other ->
          []
      end

    player_fields ++ event_fields
  end

  defp relevant?(%Event{type: type}, key) when type in [:player_kill, :player_team_kill],
    do: key in [:target_player_name, :weapon]

  defp relevant?(%Event{type: :player_chat}, key), do: key == :chat_message
  defp relevant?(_event, _key), do: false

  @doc """
  Applies submitted edits (`%{"player" => %{...}, "event" => %{...}}`).
  """
  @spec apply_edits(map(), map()) :: map()
  def apply_edits(sample, params) do
    player_params = Map.get(params, "player", %{})
    event_params = Map.get(params, "event", %{})

    player =
      Enum.reduce(player_params, sample.player || %{}, fn {key, raw}, player ->
        if key in @player_keys,
          do: Map.put(player, key, cast(Map.get(player, key), raw)),
          else: player
      end)

    event =
      case sample.event do
        %Event{} = event ->
          event
          |> Map.merge(event_edits(event_params))
          |> Map.put(:player_name, player["name"] || event.player_name)

        other ->
          other
      end

    %{sample | player: player, player_name: player["name"] || sample.player_name, event: event}
  end

  defp event_edits(params) do
    for key <- @event_keys,
        Map.has_key?(params, to_string(key)),
        into: %{},
        do: {key, blank_to_nil(params[to_string(key)])}
  end

  defp cast(old, raw) when is_integer(old) do
    case Integer.parse(String.trim(raw)) do
      {value, _rest} -> value
      :error -> old
    end
  end

  defp cast(old, raw) when is_float(old) do
    case Float.parse(String.trim(raw)) do
      {value, _rest} -> value
      :error -> old
    end
  end

  defp cast(old, raw) when is_boolean(old), do: raw in ["true", "on", "1"]
  defp cast(_old, raw), do: raw

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  @doc "Rebuilds the evaluation context of a sample on a server."
  defdelegate to_context(sample, server), to: Samples
end
