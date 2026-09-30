defmodule HllConditionalActions.Players.Actions do
  @moduledoc """
  What an admin can do to a player from the player's page: message,
  punish, kick, ban (for some hours or for good), watch or stop watching,
  give or take VIP - through the same CRCON client the rules use.

  Every action needs the `:manage_players` permission (the same one that
  lets an admin act on players from a ticket) and access to the server.
  CRCON records the action in the player's own history (`received_actions`),
  signed by the API key's user; penalties also carry the admin's name in the
  reason the player reads, the way the ticket actions do.
  """

  alias HllConditionalActions.Crcon
  alias HllConditionalActions.Players
  alias HllConditionalActions.Servers.Server

  @actions ~w(message punish kick temp_ban perma_ban watch unwatch add_vip remove_vip)a

  @doc "Every action, in the order the page offers them."
  @spec all() :: [atom()]
  def all, do: @actions

  @doc """
  Parses an action name from the page (`"temp_ban"`), without making atoms
  out of user input.

      iex> HllConditionalActions.Players.Actions.parse("kick")
      :kick
      iex> HllConditionalActions.Players.Actions.parse("launch")
      nil
  """
  @spec parse(String.t() | atom() | nil) :: atom() | nil
  def parse(action) when is_atom(action), do: if(action in @actions, do: action)
  def parse(action) when is_binary(action), do: Enum.find(@actions, &(to_string(&1) == action))
  def parse(_action), do: nil

  @doc "Whether the action needs a reason (or, for a message, the text)."
  @spec needs_reason?(atom()) :: boolean()
  def needs_reason?(action), do: action not in [:unwatch, :remove_vip]

  @doc """
  Runs `action` on `player_id` on `server` as `user`.

  Options: `:hours` for `:temp_ban` (1 to 8760), `:days` for `:add_vip`
  (nil keeps it until removed), `:player_name` for CRCON's records.
  """
  @spec run(map(), Server.t(), String.t(), atom(), String.t() | nil, keyword()) ::
          {:ok, term()}
          | {:error, :forbidden | :unknown_action | :empty_reason | :bad_duration | String.t()}
  def run(user, %Server{} = server, player_id, action, reason, opts \\ []) do
    reason = String.trim(reason || "")

    with :ok <- check(user, server, action, reason, opts) do
      case execute(server, action, player_id, text(action, reason, user), opts) do
        {:ok, result} ->
          Players.forget(server.id)
          {:ok, result}

        {:error, error} ->
          {:error, Exception.message(error)}
      end
    end
  end

  defp check(user, server, action, reason, opts) do
    cond do
      action not in @actions ->
        {:error, :unknown_action}

      not Players.can_act?(user, server) ->
        {:error, :forbidden}

      needs_reason?(action) and reason == "" ->
        {:error, :empty_reason}

      not valid_duration?(action, opts) ->
        {:error, :bad_duration}

      true ->
        :ok
    end
  end

  defp valid_duration?(:temp_ban, opts), do: valid?(opts[:hours], 1..8760)
  defp valid_duration?(:add_vip, opts), do: opts[:days] == nil or valid?(opts[:days], 1..3650)
  defp valid_duration?(_action, _opts), do: true

  defp valid?(value, range), do: is_integer(value) and value in range

  # A message goes as written; a penalty is signed, as the player sees it.
  defp text(action, reason, user) when action in [:punish, :kick, :temp_ban, :perma_ban],
    do: "#{reason} - #{admin_name(user)}"

  defp text(_action, reason, _user), do: reason

  defp admin_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp admin_name(%{username: username}), do: username

  defp execute(server, :message, id, text, _opts), do: Crcon.message_player(server, id, text)
  defp execute(server, :punish, id, text, opts), do: Crcon.punish(server, id, text, named(opts))
  defp execute(server, :kick, id, text, opts), do: Crcon.kick(server, id, text, named(opts))

  defp execute(server, :temp_ban, id, text, opts),
    do: Crcon.temp_ban(server, id, opts[:hours], text, named(opts))

  defp execute(server, :perma_ban, id, text, opts),
    do: Crcon.perma_ban(server, id, text, named(opts))

  defp execute(server, :watch, id, text, opts),
    do: Crcon.watch_player(server, id, text, named(opts))

  defp execute(server, :unwatch, id, _text, _opts), do: Crcon.unwatch_player(server, id)

  defp execute(server, :add_vip, id, text, opts) do
    expires = if opts[:days], do: DateTime.add(DateTime.utc_now(), opts[:days] * 86_400, :second)
    Crcon.add_vip(server, id, text, expires)
  end

  defp execute(server, :remove_vip, id, _text, _opts), do: Crcon.remove_vip(server, id)

  defp named(opts) do
    case opts[:player_name] do
      name when is_binary(name) and name != "" -> [player_name: name]
      _none -> []
    end
  end
end
