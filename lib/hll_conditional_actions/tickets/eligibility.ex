defmodule HllConditionalActions.Tickets.Eligibility do
  @moduledoc """
  Who may open a ticket on a server, beyond typing the command: everyone,
  players with some hours on the server, or VIPs only - and never players
  wearing one of the server's blocking CRCON flags or banned in the last
  day.

  The answers come from CRCON (the player's profile, and the live player
  list for VIP), read only when the server restricts anything. When CRCON
  cannot say, the player is let through: a server outage must not silence
  every call for help.
  """

  use Gettext, backend: HllConditionalActionsWeb.Gettext

  alias HllConditionalActions.Crcon
  alias HllConditionalActions.Tickets.Settings

  @type reason :: :vip_only | :playtime | :blocked

  @doc """
  `:ok` when the player may open a ticket, or why not.
  """
  @spec check(map(), Settings.t(), String.t()) :: :ok | {:denied, reason()}
  def check(server, %Settings{} = settings, player_id) do
    if restricted?(settings) do
      profile =
        case Crcon.get_player_profile(server, player_id) do
          {:ok, profile} when is_map(profile) -> profile
          _error -> nil
        end

      decide(settings, profile, fn -> live_vip?(server, player_id) end)
    else
      :ok
    end
  end

  @doc """
  Whether the settings restrict anyone at all.

      iex> alias HllConditionalActions.Tickets.{Eligibility, Settings}
      iex> Eligibility.restricted?(%Settings{})
      false
      iex> Eligibility.restricted?(%Settings{audience: "vip"})
      true
  """
  @spec restricted?(Settings.t()) :: boolean()
  def restricted?(%Settings{} = settings) do
    settings.audience in ["playtime", "vip"] or (settings.blocked_flags || []) != [] or
      settings.block_recent_bans == true
  end

  @doc """
  The decision, from a CRCON profile (nil when CRCON did not answer) and a
  function that says whether the player is VIP right now.

      iex> alias HllConditionalActions.Tickets.{Eligibility, Settings}
      iex> Eligibility.decide(%Settings{audience: "playtime", min_playtime_hours: 2}, %{"total_playtime_seconds" => 3600}, fn -> false end)
      {:denied, :playtime}
      iex> Eligibility.decide(%Settings{blocked_flags: ["sem_ticket"]}, %{"flags" => [%{"flag" => "sem_ticket"}]}, fn -> false end)
      {:denied, :blocked}
      iex> Eligibility.decide(%Settings{audience: "vip"}, nil, fn -> nil end)
      :ok
  """
  @spec decide(Settings.t(), map() | nil, (-> boolean() | nil)) :: :ok | {:denied, reason()}
  def decide(%Settings{} = settings, profile, vip?) do
    cond do
      blocked_flag?(settings, profile) ->
        {:denied, :blocked}

      settings.block_recent_bans and recently_banned?(profile) ->
        {:denied, :blocked}

      true ->
        audience_check(settings, profile, vip?)
    end
  end

  defp audience_check(%Settings{audience: "vip"}, profile, vip?) do
    if vip?.() == false and not profile_vip?(profile), do: {:denied, :vip_only}, else: :ok
  end

  defp audience_check(%Settings{audience: "playtime"} = settings, profile, _vip?) do
    if short_playtime?(settings, profile), do: {:denied, :playtime}, else: :ok
  end

  defp audience_check(_settings, _profile, _vip?), do: :ok

  @doc "What the player reads when refused, in the app's language."
  @spec message(reason(), Settings.t()) :: String.t()
  def message(reason, settings) do
    Gettext.with_locale(
      Application.get_env(:hll_conditional_actions, :default_locale, "en"),
      fn -> text(reason, settings) end
    )
  end

  defp text(:vip_only, _settings), do: gettext("Only VIPs can call an admin on this server.")

  defp text(:playtime, settings),
    do:
      gettext("You need %{hours} h on this server before you can call an admin.",
        hours: settings.min_playtime_hours
      )

  defp text(:blocked, _settings), do: gettext("You cannot open tickets on this server.")

  defp blocked_flag?(%Settings{blocked_flags: [_ | _] = blocked}, %{"flags" => flags})
       when is_list(flags) do
    flags
    |> Enum.flat_map(fn
      %{"flag" => flag} when is_binary(flag) -> [flag]
      flag when is_binary(flag) -> [flag]
      _other -> []
    end)
    |> Enum.any?(&(&1 in blocked))
  end

  defp blocked_flag?(_settings, _profile), do: false

  # A ban (temporary or not) that CRCON recorded in the last 24 hours.
  defp recently_banned?(%{"received_actions" => actions}) when is_list(actions) do
    since = DateTime.add(DateTime.utc_now(), -24, :hour)

    Enum.any?(actions, fn action ->
      type = to_string(action["action_type"] || action["type"] || "")

      String.contains?(String.upcase(type), "BAN") and
        case parse_time(action["time"]) do
          %DateTime{} = at -> DateTime.compare(at, since) != :lt
          nil -> false
        end
    end)
  end

  defp recently_banned?(_profile), do: false

  defp short_playtime?(%Settings{min_playtime_hours: hours}, %{
         "total_playtime_seconds" => seconds
       })
       when is_integer(seconds) and is_integer(hours),
       do: seconds < hours * 3600

  defp short_playtime?(_settings, _profile), do: false

  defp profile_vip?(%{"vips" => [_ | _]}), do: true
  defp profile_vip?(_profile), do: false

  defp live_vip?(server, player_id) do
    case Crcon.get_detailed_players(server) do
      {:ok, %{"players" => %{} = players}} ->
        case Map.get(players, player_id) do
          %{"is_vip" => vip} when is_boolean(vip) -> vip
          _other -> nil
        end

      _error ->
        nil
    end
  end

  defp parse_time(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} ->
        at

      _error ->
        case NaiveDateTime.from_iso8601(text) do
          {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
          _error -> nil
        end
    end
  end

  defp parse_time(_value), do: nil
end
