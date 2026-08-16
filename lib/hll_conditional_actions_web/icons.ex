defmodule HllConditionalActionsWeb.Icons do
  @moduledoc """
  The icon and colour each piece of the rule vocabulary is drawn with.

  Sits next to `HllConditionalActionsWeb.Labels`, which owns the words: this
  module owns the picture. Keeping it in one place is what makes a kick look
  like a kick in the builder, in the rules list and in the history alike.

  Colours are returned as whole class names rather than as a colour to
  interpolate into one, because Tailwind only ships the classes it can find
  written out in the source.
  """

  @doc """
  The heroicon of a trigger event.
  """
  @spec trigger(atom()) :: String.t()
  def trigger(:player_connected), do: "hero-arrow-right-end-on-rectangle"
  def trigger(:player_disconnected), do: "hero-arrow-right-start-on-rectangle"
  def trigger(:player_kill), do: "hero-viewfinder-circle"
  def trigger(:player_death), do: "hero-shield-exclamation"
  def trigger(:player_team_kill), do: "hero-exclamation-triangle"
  def trigger(:player_chat), do: "hero-chat-bubble-left-right"
  def trigger(:team_switch), do: "hero-arrows-right-left"
  def trigger(:match_start), do: "hero-play"
  def trigger(:match_end), do: "hero-flag"
  def trigger(:chat_command), do: "hero-command-line"
  def trigger(:periodic), do: "hero-clock"

  @doc """
  The heroicon of an action type.
  """
  @spec action(atom()) :: String.t()
  def action(:message_player), do: "hero-chat-bubble-left-ellipsis"
  def action(:message_all_players), do: "hero-megaphone"
  def action(:broadcast_message), do: "hero-speaker-wave"
  def action(:temporary_broadcast), do: "hero-speaker-wave"
  def action(:set_welcome_message), do: "hero-hand-raised"
  def action(:punish_player), do: "hero-fire"
  def action(:kick_player), do: "hero-arrow-right-start-on-rectangle"
  def action(:temp_ban_player), do: "hero-clock"
  def action(:perma_ban_player), do: "hero-no-symbol"
  def action(:switch_player_team), do: "hero-arrows-right-left"
  def action(:switch_player_on_death), do: "hero-arrow-path"
  def action(type) when type in [:add_player_flag, :remove_player_flag], do: "hero-flag"
  def action(type) when type in [:add_to_watchlist, :remove_from_watchlist], do: "hero-eye"
  def action(:grant_vip), do: "hero-star"
  def action(:remove_vip), do: "hero-star"
  def action(:blacklist_player), do: "hero-shield-exclamation"
  def action(:send_discord_webhook), do: "hero-paper-airplane"

  @doc """
  How loudly an action should read.

  Talking to a player is not the same as banning them, and the colour is the
  fastest way to tell one from the other in a list.
  """
  @spec action_tone(atom()) :: :info | :warning | :error
  def action_tone(type)
      when type in [:kick_player, :temp_ban_player, :perma_ban_player, :blacklist_player],
      do: :error

  def action_tone(type)
      when type in [
             :punish_player,
             :switch_player_team,
             :switch_player_on_death,
             :add_player_flag,
             :remove_player_flag,
             :add_to_watchlist,
             :remove_from_watchlist,
             :grant_vip,
             :remove_vip
           ],
      do: :warning

  def action_tone(_type), do: :info

  @doc """
  Text colour classes for a tone.
  """
  @spec text(:info | :warning | :error) :: String.t()
  def text(:error), do: "text-error"
  def text(:warning), do: "text-warning"
  def text(:info), do: "text-info"

  @doc """
  Badge classes for a tone.
  """
  @spec badge(:info | :warning | :error) :: String.t()
  def badge(:error), do: "badge-error"
  def badge(:warning), do: "badge-warning"
  def badge(:info), do: "badge-info"

  @doc """
  Chip classes - a tinted square holding the icon - for a tone.
  """
  @spec chip(:info | :warning | :error) :: String.t()
  def chip(:error), do: "bg-error/15 text-error"
  def chip(:warning), do: "bg-warning/15 text-warning"
  def chip(:info), do: "bg-info/15 text-info"

  @doc """
  Left border classes for a tone, used to stripe an action card.
  """
  @spec accent(:info | :warning | :error) :: String.t()
  def accent(:error), do: "border-l-error"
  def accent(:warning), do: "border-l-warning"
  def accent(:info), do: "border-l-info"
end
