defmodule HllConditionalActions.Crcon do
  @moduledoc """
  Named CRCON commands used by the rule engine and the UI.

  This is a thin, documented surface over `HllConditionalActions.Crcon.Client`.
  Every function takes a connection (any struct with `:base_url` and `:api_key`,
  typically a `HllConditionalActions.Servers.Server`) and returns
  `{:ok, result}` or `{:error, %HllConditionalActions.Crcon.Error{}}`.

  Parameter names mirror CRCON's Python signatures exactly, because the API
  passes them straight through to the underlying method. Audit fields (`by`,
  `admin_name`) are deliberately absent: CRCON fills them in from the user that
  owns the API key.
  """

  alias HllConditionalActions.Crcon.Client
  alias HllConditionalActions.Crcon.Error
  alias HllConditionalActions.Crcon.Permissions

  @type conn :: Client.connection()
  @type result :: {:ok, term()} | {:error, Error.t()}

  # ── Reads ──────────────────────────────────────────────────────────────────

  @doc """
  Returns the live game state: scores, player counts, current and next map,
  remaining time.
  """
  @spec get_gamestate(conn()) :: result()
  def get_gamestate(conn), do: Client.request(conn, "get_gamestate")

  @doc """
  Returns every connected player with their full scoreboard.

  The result is `%{"players" => %{player_id => player}, "fail_count" => n}`.
  This is the single most expensive CRCON call, so the engine fetches it once
  per evaluation cycle and shares it across rules.
  """
  @spec get_detailed_players(conn()) :: result()
  def get_detailed_players(conn), do: Client.request(conn, "get_detailed_players")

  @doc """
  Returns the lightweight player list (name, id, VIP status, country).
  """
  @spec get_players(conn()) :: result()
  def get_players(conn), do: Client.request(conn, "get_players")

  @doc """
  Returns a player's persistent profile: sessions, playtime, penalties, flags.
  """
  @spec get_player_profile(conn(), String.t(), keyword()) :: result()
  def get_player_profile(conn, player_id, opts \\ []) do
    Client.request(conn, "get_player_profile", %{
      player_id: player_id,
      num_sessions: Keyword.get(opts, :num_sessions, 0)
    })
  end

  @doc """
  Returns the public server info (name, player slots, current map, score).

  Useful as a connectivity check that does not require elevated permissions.
  """
  @spec get_public_info(conn()) :: result()
  def get_public_info(conn), do: Client.request(conn, "get_public_info")

  @doc """
  Returns the CRCON version string.
  """
  @spec get_version(conn()) :: result()
  def get_version(conn), do: Client.request(conn, "get_version")

  @doc """
  Returns the permissions of the user the API key belongs to.

  This is the endpoint the server form verifies a key against: it requires
  authentication, so reaching it at all proves the key works, and its payload
  is what `HllConditionalActions.Crcon.Permissions.review/1` checks for excess
  privileges.
  """
  @spec get_own_user_permissions(conn()) :: result()
  def get_own_user_permissions(conn), do: Client.request(conn, "get_own_user_permissions")

  @doc """
  Returns server name, player count and current map.
  """
  @spec get_status(conn()) :: result()
  def get_status(conn), do: Client.request(conn, "get_status")

  @doc """
  Returns the broadcast message currently set through CRCON, if any.
  """
  @spec get_broadcast_message(conn()) :: result()
  def get_broadcast_message(conn), do: Client.request(conn, "get_broadcast_message")

  # ── Player actions ─────────────────────────────────────────────────────────

  @doc """
  Sends a private in-game message to one player.
  """
  @spec message_player(conn(), String.t(), String.t(), keyword()) :: result()
  def message_player(conn, player_id, message, opts \\ []) do
    Client.request(conn, "message_player", %{
      player_id: player_id,
      message: message,
      save_message: Keyword.get(opts, :save_message, false)
    })
  end

  @doc """
  Sends a private in-game message to every connected player.
  """
  @spec message_all_players(conn(), String.t()) :: result()
  def message_all_players(conn, message) do
    Client.request(conn, "message_all_players", %{message: message})
  end

  @doc """
  Punishes (kills) a player in place, with a reason shown on their screen.
  """
  @spec punish(conn(), String.t(), String.t(), keyword()) :: result()
  def punish(conn, player_id, reason, opts \\ []) do
    Client.request(conn, "punish", params(%{player_id: player_id, reason: reason}, opts))
  end

  @doc """
  Kicks a player from the server.
  """
  @spec kick(conn(), String.t(), String.t(), keyword()) :: result()
  def kick(conn, player_id, reason, opts \\ []) do
    Client.request(conn, "kick", params(%{player_id: player_id, reason: reason}, opts))
  end

  @doc """
  Temporarily bans a player for `duration_hours`.
  """
  @spec temp_ban(conn(), String.t(), pos_integer(), String.t(), keyword()) :: result()
  def temp_ban(conn, player_id, duration_hours, reason, opts \\ []) do
    Client.request(
      conn,
      "temp_ban",
      params(
        %{player_id: player_id, duration_hours: duration_hours, reason: reason},
        opts
      )
    )
  end

  @doc """
  Permanently bans a player.
  """
  @spec perma_ban(conn(), String.t(), String.t(), keyword()) :: result()
  def perma_ban(conn, player_id, reason, opts \\ []) do
    Client.request(conn, "perma_ban", params(%{player_id: player_id, reason: reason}, opts))
  end

  @doc """
  Switches a player to the opposing team immediately.
  """
  @spec switch_player_now(conn(), String.t()) :: result()
  def switch_player_now(conn, player_id) do
    Client.request(conn, "switch_player_now", %{player_id: player_id})
  end

  @doc """
  Switches a player to the opposing team the next time they die.
  """
  @spec switch_player_on_death(conn(), String.t()) :: result()
  def switch_player_on_death(conn, player_id) do
    Client.request(conn, "switch_player_on_death", %{player_id: player_id})
  end

  @doc """
  Adds a flag (usually an emoji) to a player's profile.
  """
  @spec flag_player(conn(), String.t(), String.t(), keyword()) :: result()
  def flag_player(conn, player_id, flag, opts \\ []) do
    Client.request(
      conn,
      "flag_player",
      params(%{player_id: player_id, flag: flag}, opts, [:player_name, :comment])
    )
  end

  @doc """
  Removes a flag from a player's profile.
  """
  @spec unflag_player(conn(), String.t(), String.t()) :: result()
  def unflag_player(conn, player_id, flag) do
    Client.request(conn, "unflag_player", %{player_id: player_id, flag: flag})
  end

  @doc """
  Adds a player to the watchlist, which notifies admins when they connect.
  """
  @spec watch_player(conn(), String.t(), String.t(), keyword()) :: result()
  def watch_player(conn, player_id, reason, opts \\ []) do
    Client.request(conn, "watch_player", params(%{player_id: player_id, reason: reason}, opts))
  end

  @doc """
  Removes a player from the watchlist.
  """
  @spec unwatch_player(conn(), String.t()) :: result()
  def unwatch_player(conn, player_id) do
    Client.request(conn, "unwatch_player", %{player_id: player_id})
  end

  @doc """
  Grants VIP, optionally until a moment in time.

  CRCON stores the expiry alongside the in-game VIP slot, so a temporary VIP
  needs no follow-up job on our side: passing `expiration` is enough and the
  grant survives a restart of either system. Without it the VIP is
  indefinite.
  """
  @spec add_vip(conn(), String.t(), String.t(), DateTime.t() | nil) :: result()
  def add_vip(conn, player_id, description, expiration \\ nil) do
    body = %{player_id: player_id, description: description}

    body =
      case expiration do
        %DateTime{} = at -> Map.put(body, :expiration, DateTime.to_iso8601(at))
        _indefinite -> body
      end

    Client.request(conn, "add_vip", body)
  end

  @doc """
  Removes VIP.
  """
  @spec remove_vip(conn(), String.t()) :: result()
  def remove_vip(conn, player_id) do
    Client.request(conn, "remove_vip", %{player_id: player_id})
  end

  @doc """
  Adds a player to one of CRCON's blacklists.

  A blacklist record is the scalable cousin of a ban: it can expire, it
  carries a reason, and CRCON re-applies it if the player rejoins from
  another server in the same collection. `expires_at` of `nil` means
  permanent.
  """
  @spec add_blacklist_record(conn(), String.t(), integer(), String.t(), keyword()) :: result()
  def add_blacklist_record(conn, player_id, blacklist_id, reason, opts \\ []) do
    body = %{player_id: player_id, blacklist_id: blacklist_id, reason: reason}

    body =
      case Keyword.get(opts, :expires_at) do
        %DateTime{} = at -> Map.put(body, :expires_at, DateTime.to_iso8601(at))
        _permanent -> body
      end

    Client.request(conn, "add_blacklist_record", params(body, opts))
  end

  # ── Server actions ─────────────────────────────────────────────────────────

  @doc """
  Sets the rotating broadcast message shown to everyone on the server.

  CRCON has no "temporary broadcast" endpoint; the engine implements that by
  reading the current message with `get_broadcast_message/1`, setting a new one
  and restoring the original later.
  """
  @spec set_broadcast(conn(), String.t()) :: result()
  def set_broadcast(conn, message) do
    Client.request(conn, "set_broadcast", %{message: message})
  end

  @doc """
  Sets the welcome (server message) screen text.
  """
  @spec set_welcome_message(conn(), String.t()) :: result()
  def set_welcome_message(conn, message) do
    Client.request(conn, "set_welcome_message", %{message: message})
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  @doc """
  Verifies an API key and reports what it is allowed to do.

  `get_own_user_permissions` is the probe rather than `get_public_info`,
  because the public endpoint needs no authentication at all - it would answer
  happily for a wrong key. Reaching this one proves the key is valid, and its
  payload is what the least-privilege check runs on.

  The returned `:permissions` is a `HllConditionalActions.Crcon.Permissions`
  review; a connection can succeed while the key is still unacceptable, and
  the caller decides what to do about that.
  """
  @spec check_connection(conn()) :: {:ok, map()} | {:error, Error.t()}
  def check_connection(conn) do
    with {:ok, payload} <- get_own_user_permissions(conn) do
      {:ok,
       %{
         user_name: payload["user_name"],
         permissions: Permissions.review(payload),
         server: describe_server(conn)
       }}
    end
  end

  # Best effort: the server description is only there to reassure the operator
  # that they pointed at the right CRCON, so a failure here must not fail the
  # check.
  defp describe_server(conn) do
    case get_public_info(conn) do
      {:ok, info} when is_map(info) ->
        %{
          name: get_in(info, ["name", "name"]) || info["short_name"],
          player_count: info["player_count"],
          max_player_count: info["max_player_count"],
          current_map: get_in(info, ["current_map", "map", "pretty_name"])
        }

      _other ->
        nil
    end
  end

  defp params(base, opts, extra_keys \\ [:player_name]) do
    Enum.reduce(extra_keys, base, fn key, acc ->
      case Keyword.get(opts, key) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end
end
