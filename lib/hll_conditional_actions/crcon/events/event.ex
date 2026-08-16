defmodule HllConditionalActions.Crcon.Events.Event do
  @moduledoc """
  A normalized CRCON game event.

  Built by `HllConditionalActions.Crcon.Events.from_log/2`. Player 1 of the raw
  log line is always the actor and player 2 the target, so `player_id` is who
  did the thing and `target_player_id` is who it happened to.
  """

  @type type ::
          :player_connected
          | :player_disconnected
          | :player_kill
          | :player_team_kill
          | :player_chat
          | :team_switch
          | :match_start
          | :match_end
          | :admin_action
          | :camera
          | :vote
          | :unknown

  @type t :: %__MODULE__{
          server_id: term(),
          game: :hll | :hllv | nil,
          type: type(),
          action: String.t(),
          player_id: String.t() | nil,
          player_name: String.t() | nil,
          target_player_id: String.t() | nil,
          target_player_name: String.t() | nil,
          weapon: String.t() | nil,
          message: String.t() | nil,
          chat_message: String.t() | nil,
          chat_team: String.t() | nil,
          chat_scope: String.t() | nil,
          occurred_at: DateTime.t(),
          raw: map()
        }

  @enforce_keys [:type, :action, :occurred_at]
  defstruct [
    :server_id,
    :game,
    :type,
    :action,
    :player_id,
    :player_name,
    :target_player_id,
    :target_player_name,
    :weapon,
    :message,
    :chat_message,
    :chat_team,
    :chat_scope,
    :occurred_at,
    raw: %{}
  ]
end
