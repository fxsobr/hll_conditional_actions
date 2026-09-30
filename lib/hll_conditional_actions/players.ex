defmodule HllConditionalActions.Players do
  @moduledoc """
  The players area: who is playing now, who is VIP or watched, and what
  CRCON remembers about everyone else.

  CRCON is read per server, never per player row: one live player list
  (`get_detailed_players`), one VIP list (`get_vip_ids`) and one watchlist
  (`get_players_history` filtered on the watched) per server, each cached
  for a short window in `HllConditionalActions.Players.Cache`.

  Every read that carries a player's persistent profile - the live list,
  the watchlist, a history search, the player's own page - leaves its
  summary in `HllConditionalActions.Players.Profile`, the local directory
  the list searches, filters, counts and sorts (see
  `HllConditionalActions.Players.Directory`).
  """

  import Ecto.Query

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Crcon
  alias HllConditionalActions.Crcon.Client
  alias HllConditionalActions.Crcon.LogStream
  alias HllConditionalActions.Players.Cache
  alias HllConditionalActions.Players.Profile
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Servers
  alias HllConditionalActions.Servers.Server

  @live_ttl :timer.seconds(20)
  @vip_ttl :timer.seconds(60)
  @watch_ttl :timer.minutes(2)
  @history_ttl :timer.minutes(10)
  @chat_ttl :timer.minutes(3)
  @timeout :timer.seconds(8)

  @typedoc "A player on a server right now."
  @type live_entry :: %{
          server_id: term(),
          server_name: String.t(),
          stream?: boolean(),
          name: String.t() | nil,
          team: String.t() | nil,
          role: String.t() | nil,
          level: integer() | nil,
          clan_tag: String.t() | nil,
          kills: integer(),
          deaths: integer(),
          team_kills: integer(),
          platform: String.t() | nil,
          top_killer?: boolean()
        }

  # ── Servers ────────────────────────────────────────────────────────────────

  @doc "The enabled servers a user may see, by name."
  @spec servers_for(map() | nil) :: [Server.t()]
  def servers_for(user) do
    user |> Servers.list_servers_for() |> Enum.filter(& &1.enabled)
  end

  @doc """
  A server's name without its tail: "BR #1 Público" reads "BR #1", as the
  list's columns show it. Names without a number stay whole.

      iex> HllConditionalActions.Players.short_name("BR #1 Público")
      "BR #1"
      iex> HllConditionalActions.Players.short_name("Caveiras")
      "Caveiras"
  """
  @spec short_name(String.t() | nil) :: String.t()
  def short_name(nil), do: ""

  def short_name(name) do
    case Regex.run(~r/^(.*?#\s*\d+)/u, name) do
      [_all, short] -> String.trim(short)
      nil -> name
    end
  end

  # ── Live ───────────────────────────────────────────────────────────────────

  @doc """
  Everybody playing on `servers` right now, by player ID, plus which servers
  answered: `{%{player_id => live_entry}, %{server_id => :ok | :error}}`.
  """
  @spec live([Server.t()], keyword()) ::
          {%{String.t() => live_entry()}, %{term() => :ok | :error}}
  def live(servers, opts \\ []) do
    results =
      servers
      |> Task.async_stream(
        fn server ->
          {server, cached({:live, server.id}, @live_ttl, opts, fn -> read_live(server) end)}
        end,
        timeout: @timeout * 2,
        on_timeout: :kill_task,
        max_concurrency: 6
      )
      |> Enum.zip(servers)
      |> Enum.map(fn
        {{:ok, {server, result}}, _server} -> {server, result}
        {{:exit, _reason}, server} -> {server, :error}
      end)

    players =
      for {server, {:ok, entries}} <- results, {id, entry} <- entries, into: %{} do
        {id, Map.merge(entry, %{server_id: server.id, server_name: server.name})}
      end

    status =
      Map.new(results, fn {server, result} ->
        {server.id, if(result == :error, do: :error, else: :ok)}
      end)

    {players, status}
  end

  defp read_live(server) do
    case request(server, "get_detailed_players") do
      {:ok, %{"players" => players}} when is_map(players) ->
        stream? = stream_up?(server)
        top = top_killer(players)
        remember_live(server, players)

        {:ok,
         Map.new(players, fn {id, player} ->
           {id, live_entry(player, stream?, id == top)}
         end)}

      _error ->
        :error
    end
  end

  defp live_entry(player, stream?, top?) do
    %{
      stream?: stream?,
      name: player["name"],
      team: team(player["team"]),
      role: player["role"],
      level: integer(player["level"]),
      clan_tag: blank_to_nil(player["clan_tag"]),
      kills: integer(player["kills"]) || 0,
      deaths: integer(player["deaths"]) || 0,
      team_kills: integer(player["team_kills"] || player["teamkills"]) || 0,
      platform: player["platform"],
      top_killer?: top?
    }
  end

  # The best killer of the match, when somebody has killed at all.
  defp top_killer(players) do
    case Enum.max_by(players, fn {_id, p} -> integer(p["kills"]) || 0 end, fn -> nil end) do
      {id, %{"kills" => kills}} when is_integer(kills) and kills > 0 -> id
      _none -> nil
    end
  end

  defp team(team) when team in ["allies", "axis"], do: team
  defp team(%{"side" => side}), do: team(String.downcase(to_string(side)))
  defp team(team) when is_binary(team), do: team |> String.downcase() |> team_name()
  defp team(_team), do: nil

  defp team_name(team) when team in ["allies", "axis"], do: team
  defp team_name(_team), do: nil

  # A server whose log stream is not connected is still readable over the
  # API, but the app sees none of its events: the list says so.
  defp stream_up?(%Server{log_stream_enabled: false}), do: false
  defp stream_up?(server), do: LogStream.status(server.id) == :connected

  # ── VIP and watchlist ──────────────────────────────────────────────────────

  @doc """
  The VIPs of `servers`, by player ID: `%{expires_at, server_ids}` (the
  latest expiry; `nil` never expires).
  """
  @spec vips([Server.t()], keyword()) :: %{
          String.t() => %{expires_at: DateTime.t() | nil, server_ids: list()}
        }
  def vips(servers, opts \\ []) do
    servers
    |> per_server(fn server ->
      cached({:vips, server.id}, @vip_ttl, opts, fn -> read_vips(server) end)
    end)
    |> Enum.reduce(%{}, fn {server, entries}, acc ->
      Enum.reduce(entries, acc, &merge_vip(&1, &2, server))
    end)
  end

  defp merge_vip({id, expires_at}, acc, server) do
    Map.update(acc, id, %{expires_at: expires_at, server_ids: [server.id]}, fn current ->
      %{
        expires_at: later(current.expires_at, expires_at),
        server_ids: Enum.uniq([server.id | current.server_ids])
      }
    end)
  end

  defp read_vips(server) do
    case request(server, "get_vip_ids") do
      {:ok, list} when is_list(list) ->
        now = DateTime.utc_now()

        entries =
          list
          |> Enum.filter(&(is_map(&1) and is_binary(&1["player_id"])))
          |> Enum.map(&{&1["player_id"], datetime(&1["vip_expiration"])})
          |> Enum.filter(fn {_id, at} -> at == nil or DateTime.compare(at, now) == :gt end)
          |> Map.new(fn {id, at} -> {id, if(far_future?(at), do: nil, else: at)} end)

        remember_names(server, for(%{"player_id" => id, "name" => name} <- list, do: {id, name}))
        {:ok, entries}

      _error ->
        :error
    end
  end

  # CRCON writes "never" as a date around the year 3000.
  defp far_future?(nil), do: false
  defp far_future?(at), do: at.year >= 2900

  defp later(nil, _other), do: nil
  defp later(_other, nil), do: nil
  defp later(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)

  @doc """
  The watched players of `servers`, by player ID: `%{reason, by}`.
  """
  @spec watchlist([Server.t()], keyword()) :: %{
          String.t() => %{reason: String.t() | nil, by: String.t() | nil}
        }
  def watchlist(servers, opts \\ []) do
    servers
    |> per_server(fn server ->
      cached({:watch, server.id}, @watch_ttl, opts, fn -> read_watchlist(server) end)
    end)
    |> Enum.reduce(%{}, fn {_server, entries}, acc -> Map.merge(acc, entries) end)
  end

  defp read_watchlist(server) do
    case history(server, %{is_watched: true, page: 1, page_size: 200}) do
      {:ok, players} ->
        watched = Enum.filter(players, &watched?(&1["watchlist"]))
        remember_profiles(server, watched)

        {:ok,
         Map.new(watched, fn profile ->
           {profile["player_id"],
            %{reason: profile["watchlist"]["reason"], by: profile["watchlist"]["by"]}}
         end)}

      :error ->
        :error
    end
  end

  defp watched?(%{"is_watched" => true}), do: true
  defp watched?(_watchlist), do: false

  # With `cached_only: true`, only what is already cached: the first render
  # of a page shows what another page just read, without waiting on CRCON.
  defp cached(key, ttl, opts, fun) do
    if Keyword.get(opts, :cached_only, false) do
      case Cache.peek(key, ttl) do
        {:ok, value} -> value
        :miss -> :error
      end
    else
      Cache.fetch(key, ttl, fun)
    end
  end

  defp per_server(servers, fun) do
    servers
    |> Task.async_stream(fn server -> {server, fun.(server)} end,
      timeout: @timeout * 2,
      on_timeout: :kill_task,
      max_concurrency: 6
    )
    |> Enum.flat_map(fn
      {:ok, {server, {:ok, value}}} -> [{server, value}]
      _error -> []
    end)
  end

  # ── CRCON's player history ─────────────────────────────────────────────────

  @doc """
  Reads the most recently seen page of each server's player history into
  the directory, at most once per #{div(@history_ttl, 60_000)} minutes per
  server. Returns how many profiles were read.
  """
  @spec sync_history([Server.t()]) :: non_neg_integer()
  def sync_history(servers) do
    servers
    |> Enum.filter(&Cache.due?({:history, &1.id}, @history_ttl))
    |> per_server(fn server ->
      case history(server, %{page: 1, page_size: 100}) do
        {:ok, players} ->
          remember_profiles(server, players)
          {:ok, length(players)}

        :error ->
          :error
      end
    end)
    |> Enum.map(fn {_server, count} -> count end)
    |> Enum.sum()
  end

  @doc """
  Searches CRCON's player history of `servers` by name, and what players
  wrote in the chat lately, remembering what it finds. Returns the IDs
  found, so the list can include players it had never recorded.
  """
  @spec search_history([Server.t()], String.t()) :: [String.t()]
  def search_history(servers, term) do
    term = String.trim(term)

    if String.length(term) < 3 do
      []
    else
      by_name = per_server(servers, &cached_search(&1, term))

      in_chat = per_server(servers, fn server -> {:ok, chat_authors(server, term)} end)

      (by_name ++ in_chat)
      |> Enum.flat_map(fn {_server, ids} -> ids end)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
    end
  end

  defp cached_search(server, term) do
    Cache.fetch({:search, server.id, String.downcase(term)}, @chat_ttl, fn ->
      search_by_name(server, term)
    end)
  end

  defp search_by_name(server, term) do
    case history(server, %{player_name: term, page: 1, page_size: 30}) do
      {:ok, players} ->
        remember_profiles(server, players)
        {:ok, Enum.map(players, & &1["player_id"])}

      :error ->
        :error
    end
  end

  # CRCON's log history has no filter on what was said, so the recent chat
  # lines are read once per window and searched here.
  defp chat_authors(server, term) do
    needle = String.downcase(term)

    server
    |> recent_chat()
    |> Enum.filter(fn {_id, _name, text} -> String.contains?(String.downcase(text), needle) end)
    |> Enum.map(fn {id, _name, _text} -> id end)
  end

  defp recent_chat(server) do
    case Cache.fetch({:chat, server.id}, @chat_ttl, fn -> read_chat(server) end) do
      {:ok, lines} -> lines
      :error -> []
    end
  end

  defp read_chat(server) do
    case request(server, "get_historical_logs", %{action: "CHAT", limit: 1500}) do
      {:ok, logs} when is_list(logs) ->
        {:ok,
         for log <- logs,
             is_map(log),
             String.starts_with?(to_string(log["action"] || log["type"]), "CHAT"),
             id = log["player_id_1"] || log["player1_id"] || log["player_id"],
             is_binary(id),
             text = chat_text(log),
             is_binary(text) do
           {id, log["player_name_1"] || log["player1_name"] || log["player_name"], text}
         end}

      _error ->
        :error
    end
  end

  defp chat_text(log), do: log["sub_content"] || log["content"] || log["message"]

  defp history(server, params) do
    case request(server, "get_players_history", params, method: :post) do
      {:ok, %{"players" => players}} when is_list(players) ->
        {:ok, Enum.filter(players, &is_map/1)}

      _error ->
        :error
    end
  end

  # ── One player ─────────────────────────────────────────────────────────────

  @doc """
  A player's persistent profile on a server, parsed, and remembered in the
  directory: `{:ok, profile}` or `:error` when CRCON does not answer or does
  not know them.
  """
  @spec profile(Server.t(), String.t()) :: {:ok, map()} | :error
  def profile(%Server{} = server, player_id) do
    case Crcon.get_player_profile(server, player_id) do
      {:ok, %{} = raw} ->
        remember_profiles(server, [raw])
        {:ok, parse_profile(raw)}

      _error ->
        :error
    end
  end

  @doc """
  A CRCON profile as the pages use it.
  """
  @spec parse_profile(map()) :: map()
  def parse_profile(raw) do
    %{
      name: current_name(raw),
      names: names(raw["names"]),
      sessions: integer(raw["sessions_count"]),
      playtime_seconds: integer(raw["total_playtime_seconds"]),
      penalty_counts: penalty_counts(raw["penalty_count"]),
      penalties: raw["penalty_count"] |> penalty_counts() |> Map.values() |> Enum.sum(),
      actions: received_actions(raw["received_actions"]),
      flags: flags(raw["flags"]),
      watch:
        if(watched?(raw["watchlist"]),
          do: %{reason: raw["watchlist"]["reason"], by: raw["watchlist"]["by"]}
        ),
      blacklisted?: raw["is_blacklisted"] == true,
      vip_expires: vip_expiry(raw["vips"]),
      vip?: raw["is_vip"] == true or (is_list(raw["vips"]) and raw["vips"] != []),
      first_seen_at: ms_datetime(raw["first_seen_timestamp_ms"]) || datetime(raw["created"]),
      last_seen_at: ms_datetime(raw["last_seen_timestamp_ms"]),
      platform: platform(raw)
    }
  end

  defp current_name(raw) do
    case raw["names"] do
      [_ | _] = names ->
        names
        |> Enum.filter(&is_map/1)
        |> Enum.max_by(&(datetime(&1["last_seen"]) || ~U[1970-01-01 00:00:00Z]), DateTime, fn ->
          nil
        end)
        |> case do
          %{"name" => name} -> name
          _none -> nil
        end

      _none ->
        raw["name"]
    end
  end

  defp names(names) when is_list(names) do
    names
    |> Enum.flat_map(fn
      %{"name" => name} when is_binary(name) -> [name]
      name when is_binary(name) -> [name]
      _other -> []
    end)
    |> Enum.uniq()
  end

  defp names(_names), do: []

  defp penalty_counts(counts) when is_map(counts) do
    for {type, count} <- counts, is_integer(count), count > 0, into: %{}, do: {type, count}
  end

  defp penalty_counts(_counts), do: %{}

  defp received_actions(actions) when is_list(actions) do
    actions
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn action ->
      %{
        type: to_string(action["action_type"] || ""),
        reason: blank_to_nil(action["reason"]),
        by: blank_to_nil(action["by"]),
        at: datetime(action["time"])
      }
    end)
    |> Enum.reject(&is_nil(&1.at))
  end

  defp received_actions(_actions), do: []

  defp flags(flags) when is_list(flags) do
    Enum.flat_map(flags, fn
      %{"flag" => flag} = entry when is_binary(flag) ->
        [%{"flag" => flag, "comment" => blank_to_nil(entry["comment"])}]

      _other ->
        []
    end)
  end

  defp flags(_flags), do: []

  defp vip_expiry(vips) when is_list(vips) and vips != [] do
    vips
    |> Enum.map(&datetime(&1["expiration"]))
    |> Enum.reject(&(is_nil(&1) or far_future?(&1)))
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp vip_expiry(_vips), do: nil

  defp platform(%{"steaminfo" => %{}}), do: "steam"
  defp platform(%{"platform" => platform}) when is_binary(platform), do: platform
  defp platform(_raw), do: nil

  # ── The directory ──────────────────────────────────────────────────────────

  @doc """
  Remembers the summaries of CRCON profiles (`get_player_profile`,
  `get_players_history` rows) seen on `server`.
  """
  @spec remember_profiles(Server.t(), [map()]) :: :ok
  def remember_profiles(_server, []), do: :ok

  def remember_profiles(%Server{} = server, raws) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      raws
      |> Enum.filter(&is_binary(&1["player_id"]))
      |> Enum.uniq_by(& &1["player_id"])
      |> Enum.map(fn raw ->
        profile = parse_profile(raw)

        %{
          player_id: raw["player_id"],
          name: profile.name,
          server_ids: [server.id],
          first_seen_at: truncate(profile.first_seen_at),
          last_seen_at: truncate(profile.last_seen_at),
          sessions: profile.sessions,
          playtime_seconds: profile.playtime_seconds,
          penalties: profile.penalties,
          penalty_counts: profile.penalty_counts,
          flags: profile.flags,
          synced_at: now,
          inserted_at: now,
          updated_at: now
        }
      end)

    upsert(rows, profile_conflict())
  end

  # Who is online: their name, level and clan tag, last seen now - and the
  # profile the live list carries, when it does.
  defp remember_live(server, players) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {with_profile, without} =
      Enum.split_with(players, fn {_id, player} -> is_map(player["profile"]) end)

    remember_profiles(
      server,
      Enum.map(with_profile, fn {id, player} -> Map.put(player["profile"], "player_id", id) end)
    )

    rows =
      Enum.map(with_profile ++ without, fn {id, player} ->
        %{
          player_id: id,
          name: player["name"],
          server_ids: [server.id],
          last_seen_at: now,
          level: integer(player["level"]),
          clan_tag: blank_to_nil(player["clan_tag"]),
          inserted_at: now,
          updated_at: now
        }
      end)

    upsert(rows, presence_conflict())
  end

  defp remember_names(_server, []), do: :ok

  defp remember_names(server, pairs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      pairs
      |> Enum.filter(fn {id, _name} -> is_binary(id) end)
      |> Enum.uniq_by(fn {id, _name} -> id end)
      |> Enum.map(fn {id, name} ->
        %{
          player_id: id,
          name: blank_to_nil(name),
          server_ids: [server.id],
          inserted_at: now,
          updated_at: now
        }
      end)

    upsert(rows, presence_conflict())
  end

  defp upsert([], _conflict), do: :ok

  defp upsert(rows, conflict) do
    rows
    |> Enum.chunk_every(500)
    |> Enum.each(fn chunk ->
      Repo.insert_all(Profile, chunk, on_conflict: conflict, conflict_target: [:player_id])
    end)

    :ok
  rescue
    # The directory is a cache of CRCON: failing to write it never fails a page.
    _error in [Postgrex.Error, DBConnection.ConnectionError] -> :ok
  end

  defp profile_conflict do
    from p in Profile,
      update: [
        set: [
          name: fragment("COALESCE(EXCLUDED.name, ?)", p.name),
          server_ids:
            fragment("ARRAY(SELECT DISTINCT unnest(? || EXCLUDED.server_ids))", p.server_ids),
          first_seen_at: fragment("LEAST(?, EXCLUDED.first_seen_at)", p.first_seen_at),
          last_seen_at: fragment("GREATEST(?, EXCLUDED.last_seen_at)", p.last_seen_at),
          sessions: fragment("GREATEST(?, EXCLUDED.sessions)", p.sessions),
          playtime_seconds:
            fragment("GREATEST(?, EXCLUDED.playtime_seconds)", p.playtime_seconds),
          penalties: fragment("EXCLUDED.penalties"),
          penalty_counts: fragment("EXCLUDED.penalty_counts"),
          flags: fragment("EXCLUDED.flags"),
          synced_at: fragment("EXCLUDED.synced_at"),
          updated_at: fragment("EXCLUDED.updated_at")
        ]
      ]
  end

  defp presence_conflict do
    from p in Profile,
      update: [
        set: [
          name: fragment("COALESCE(EXCLUDED.name, ?)", p.name),
          server_ids:
            fragment("ARRAY(SELECT DISTINCT unnest(? || EXCLUDED.server_ids))", p.server_ids),
          last_seen_at: fragment("GREATEST(?, EXCLUDED.last_seen_at)", p.last_seen_at),
          level: fragment("COALESCE(EXCLUDED.level, ?)", p.level),
          clan_tag: fragment("COALESCE(EXCLUDED.clan_tag, ?)", p.clan_tag),
          updated_at: fragment("EXCLUDED.updated_at")
        ]
      ]
  end

  @doc "The directory entry of a player, or nil."
  @spec get_profile(String.t()) :: Profile.t() | nil
  def get_profile(player_id), do: Repo.get_by(Profile, player_id: player_id)

  @doc "Forgets the cached lists of a server, after an action changed them."
  @spec forget(term()) :: :ok
  def forget(server_id) do
    Enum.each([:live, :vips, :watch], &Cache.delete({&1, server_id}))
  end

  @doc "Whether a user may act on players of a server (message, punish, ban…)."
  @spec can_act?(map() | nil, Server.t() | term()) :: boolean()
  def can_act?(user, server) do
    Accounts.can?(user, :manage_players) and Accounts.can_access_server?(user, server)
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp request(server, endpoint, params \\ %{}, opts \\ []) do
    Client.request(
      server,
      endpoint,
      params,
      Keyword.merge([receive_timeout: @timeout, retry: false], opts)
    )
  rescue
    _error -> :error
  catch
    :exit, _reason -> :error
  end

  defp integer(value) when is_integer(value), do: value
  defp integer(value) when is_float(value), do: round(value)
  defp integer(_value), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(_value), do: nil

  defp truncate(nil), do: nil
  defp truncate(%DateTime{} = at), do: DateTime.truncate(at, :second)

  defp ms_datetime(ms) when is_integer(ms) and ms > 0 do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, at} -> at
      _error -> nil
    end
  end

  defp ms_datetime(_ms), do: nil

  @doc false
  def datetime(nil), do: nil
  def datetime(%DateTime{} = at), do: at

  def datetime(value) when is_integer(value),
    do: ms_datetime(if value < 100_000_000_000, do: value * 1000, else: value)

  def datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} ->
        at

      {:error, _reason} ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
          {:error, _reason} -> nil
        end
    end
  end

  def datetime(_value), do: nil
end
