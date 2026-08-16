defmodule HllConditionalActions.Crcon.Permissions do
  @moduledoc """
  The CRCON permissions this application uses, and the check that keeps a
  server's API key from carrying any more than that.

  An API key is a full credential for a game server. If the key this app is
  given can also change server settings, manage admins or delete records, then
  a bug here - or anyone who reads the key out of the database - inherits all
  of it. So the key is verified when a server is saved: every permission it
  holds must be one this app would actually call.

  ## Required

  `can_view_structured_logs` is the only permission that is *always* needed:
  without it CRCON refuses the log stream and no event-triggered rule can ever
  fire.

  ## Reads

  The other entries in `reads/0` are what the engine calls while evaluating.
  They do not block saving a server - a rule can be written that needs none of
  them - but a key without `can_view_detailed_players` makes every condition
  about a player go blind, and CRCON answers 403 where nobody is looking. So
  the review reports them as `missing_reads` and the connection test says what
  each one costs.

  ## Allowed

  Everything else in `allowed/0` is optional and maps to a specific rule
  action - a key without `can_kick_players` simply means kick actions will
  fail, which the execution history records. A permission outside that list is
  rejected, because nothing in this app can use it.
  """

  # Reads the engine performs on every evaluation cycle.
  @reads ~w(
    can_view_structured_logs
    can_view_detailed_players
    can_view_gamestate
    can_view_player_profile
    can_view_broadcast_message
    can_view_get_status
  )

  # One entry per action in `HllConditionalActions.Rules.Catalog`.
  @actions %{
    "can_message_players" => [:message_player, :message_all_players],
    "can_punish_players" => [:punish_player],
    "can_kick_players" => [:kick_player],
    "can_temp_ban_players" => [:temp_ban_player],
    "can_perma_ban_players" => [:perma_ban_player],
    "can_switch_players_immediately" => [:switch_player_team],
    "can_switch_players_on_death" => [:switch_player_on_death],
    "can_flag_player" => [:add_player_flag],
    "can_unflag_player" => [:remove_player_flag],
    "can_add_player_watch" => [:add_to_watchlist],
    "can_remove_player_watch" => [:remove_from_watchlist],
    "can_change_broadcast_message" => [:broadcast_message, :temporary_broadcast],
    "can_change_welcome_message" => [:set_welcome_message],
    "can_add_vip" => [:grant_vip],
    "can_remove_vip" => [:remove_vip],
    "can_add_blacklist_records" => [:blacklist_player]
  }

  @required ["can_view_structured_logs"]

  @doc """
  The permission a key cannot work without.
  """
  @spec required() :: [String.t()]
  def required, do: @required

  @doc """
  The reads the engine performs, beyond the one it cannot start without.

      iex> "can_view_detailed_players" in HllConditionalActions.Crcon.Permissions.reads()
      true
  """
  @spec reads() :: [String.t()]
  def reads, do: @reads -- @required

  @doc """
  Every permission this app is able to use.

      iex> alias HllConditionalActions.Crcon.Permissions
      iex> "can_kick_players" in Permissions.allowed()
      true
      iex> "can_change_server_settings" in Permissions.allowed()
      false
  """
  @spec allowed() :: [String.t()]
  def allowed, do: Enum.sort(@reads ++ Map.keys(@actions))

  @doc """
  The rule actions a permission unlocks, for explaining what is missing.

      iex> HllConditionalActions.Crcon.Permissions.actions_for("can_kick_players")
      [:kick_player]
  """
  @spec actions_for(String.t()) :: [atom()]
  def actions_for(permission), do: Map.get(@actions, permission, [])

  @doc """
  The CRCON permission an action needs, or `nil` when it needs none.

  The reverse of `actions_for/1`, used to warn that a rule's action can never
  succeed with the key a server holds.

      iex> HllConditionalActions.Crcon.Permissions.permission_for(:kick_player)
      "can_kick_players"
      iex> HllConditionalActions.Crcon.Permissions.permission_for(:send_discord_webhook)
      nil
  """
  @spec permission_for(atom()) :: String.t() | nil
  def permission_for(action) do
    Enum.find_value(@actions, fn {permission, actions} ->
      if action in actions, do: permission
    end)
  end

  @doc """
  The permission a rule action needs.

      iex> HllConditionalActions.Crcon.Permissions.for_action(:temp_ban_player)
      "can_temp_ban_players"
  """
  @spec for_action(atom()) :: String.t() | nil
  def for_action(action) do
    Enum.find_value(@actions, fn {permission, actions} ->
      if action in actions, do: permission
    end)
  end

  @doc """
  Reviews the permissions CRCON reports for an API key.

  Returns a report rather than a boolean, because the UI needs to say exactly
  which permissions are excess and which rule actions the key cannot perform.

  A superuser key is always rejected: superusers bypass permission checks
  entirely in Django, so its reported permission list says nothing about what
  it can really do.

      iex> alias HllConditionalActions.Crcon.Permissions
      iex> report = Permissions.review(%{"is_superuser" => false, "permissions" => [
      ...>   %{"permission" => "can_view_structured_logs"}
      ...> ]})
      iex> {report.ok?, report.excess, report.missing_required}
      {true, [], []}
      iex> "can_view_detailed_players" in report.missing_reads
      true
  """
  @spec review(map()) :: %{
          ok?: boolean(),
          superuser?: boolean(),
          granted: [String.t()],
          excess: [String.t()],
          missing_required: [String.t()],
          missing_reads: [String.t()],
          unavailable_actions: [atom()],
          user_name: String.t() | nil
        }
  def review(payload) when is_map(payload) do
    granted = extract(payload)
    superuser? = payload["is_superuser"] == true

    excess = Enum.sort(granted -- allowed())
    missing_required = Enum.sort(@required -- granted)
    missing_reads = Enum.sort(reads() -- granted)

    unavailable =
      @actions
      |> Enum.reject(fn {permission, _actions} -> permission in granted end)
      |> Enum.flat_map(fn {_permission, actions} -> actions end)
      |> Enum.sort()

    %{
      ok?: not superuser? and excess == [] and missing_required == [],
      superuser?: superuser?,
      granted: Enum.sort(granted),
      excess: excess,
      missing_required: missing_required,
      missing_reads: missing_reads,
      unavailable_actions: unavailable,
      user_name: payload["user_name"]
    }
  end

  # CRCON returns `[%{"permission" => name, "description" => text}]`, but a
  # plain list of names is accepted too so tests and other callers stay simple.
  defp extract(%{"permissions" => permissions}) when is_list(permissions) do
    permissions
    |> Enum.map(fn
      %{"permission" => name} -> name
      name when is_binary(name) -> name
      _other -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&strip_prefix/1)
    |> Enum.uniq()
  end

  defp extract(_payload), do: []

  # Django reports codenames bare, but its permission maps are written
  # "api.can_kick_players"; accept either spelling.
  defp strip_prefix("api." <> name), do: name
  defp strip_prefix(name), do: name
end
