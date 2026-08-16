defmodule HllConditionalActions.Engine.Executor do
  @moduledoc """
  Runs a rule's actions against CRCON.

  Every action is attempted even if an earlier one fails, so a broken Discord
  webhook cannot stop a kick from happening. Each attempt produces a result map
  that ends up in the `rule_executions` audit row.

  ## Inline versus queued

  In-game consequences (message, punish, kick, ban, team switch, flags) run
  inline: a kick that lands thirty seconds late punishes a situation that has
  already passed, so retrying it later would be worse than failing. Everything
  that is safe to retry or must happen *later* goes through Oban instead:

    * `send_discord_webhook` - `HllConditionalActions.Workers.DeliverWebhook`
    * restoring a `temporary_broadcast` -
      `HllConditionalActions.Workers.RestoreBroadcast`

  CRCON has no "broadcast for N seconds" endpoint, so the temporary broadcast
  sets the message now and queues the restore, which then survives a deploy or
  a crash in between.
  """

  require Logger

  alias HllConditionalActions.Crcon
  alias HllConditionalActions.Crcon.Error
  alias HllConditionalActions.Engine.Context
  alias HllConditionalActions.Engine.Template
  alias HllConditionalActions.Rules.Action
  alias HllConditionalActions.Workers.DeliverWebhook
  alias HllConditionalActions.Workers.RestoreBroadcast

  @type result :: %{
          type: atom(),
          status: :ok | :error | :skipped,
          detail: String.t() | nil
        }

  @doc """
  Runs every action of a rule and returns one result per action.
  """
  @spec run([Action.t()], Context.t()) :: [result()]
  def run(actions, %Context{} = context) do
    Enum.map(actions, &run_action(&1, context))
  end

  @doc """
  Describes what every action *would* do, without touching CRCON.

  Used by rules in simulation. The detail is rendered exactly as the real run
  would render it - templates and all - so what you read in the history is the
  message that would have been sent.
  """
  @spec preview([Action.t()], Context.t()) :: [result()]
  def preview(actions, %Context{} = context) do
    Enum.map(actions, fn action ->
      %{type: action.type, status: :simulated, detail: detail(action, context)}
    end)
  end

  @doc """
  Runs a single action.
  """
  @spec run_action(Action.t(), Context.t()) :: result()
  def run_action(%Action{} = action, %Context{} = context) do
    case execute(action, context) do
      :ok ->
        %{type: action.type, status: :ok, detail: detail(action, context)}

      {:ok, _result} ->
        %{type: action.type, status: :ok, detail: detail(action, context)}

      {:skip, reason} ->
        %{type: action.type, status: :skipped, detail: reason}

      {:error, %Error{} = error} ->
        %{type: action.type, status: :error, detail: Exception.message(error)}

      {:error, reason} ->
        %{type: action.type, status: :error, detail: to_string(reason)}
    end
  rescue
    exception ->
      Logger.error("""
      [engine] action #{action.type} crashed: #{Exception.message(exception)}
      #{Exception.format_stacktrace(__STACKTRACE__)}
      """)

      %{type: action.type, status: :error, detail: Exception.message(exception)}
  end

  # ── Messaging ──────────────────────────────────────────────────────────────

  defp execute(%Action{type: :message_player} = action, context) do
    with_player(context, fn player_id ->
      Crcon.message_player(context.server, player_id, text(action, :message, context))
    end)
  end

  defp execute(%Action{type: :message_all_players} = action, context) do
    Crcon.message_all_players(context.server, text(action, :message, context))
  end

  defp execute(%Action{type: :broadcast_message} = action, context) do
    Crcon.set_broadcast(context.server, text(action, :message, context))
  end

  defp execute(%Action{type: :set_welcome_message} = action, context) do
    Crcon.set_welcome_message(context.server, text(action, :message, context))
  end

  defp execute(%Action{type: :temporary_broadcast} = action, context) do
    message = text(action, :message, context)
    seconds = integer(action, :duration_seconds, 60)

    previous =
      case Crcon.get_broadcast_message(context.server) do
        {:ok, current} when is_binary(current) -> current
        _other -> ""
      end

    with {:ok, _result} <- Crcon.set_broadcast(context.server, message),
         {:ok, _job} <- RestoreBroadcast.schedule(context.server.id, previous, seconds) do
      {:ok, :broadcasting}
    end
  end

  # ── Punishments ────────────────────────────────────────────────────────────

  defp execute(%Action{type: :punish_player} = action, context) do
    with_player(context, fn player_id ->
      Crcon.punish(context.server, player_id, text(action, :reason, context),
        player_name: context.player_name
      )
    end)
  end

  defp execute(%Action{type: :kick_player} = action, context) do
    with_player(context, fn player_id ->
      Crcon.kick(context.server, player_id, text(action, :reason, context),
        player_name: context.player_name
      )
    end)
  end

  defp execute(%Action{type: :temp_ban_player} = action, context) do
    with_player(context, fn player_id ->
      Crcon.temp_ban(
        context.server,
        player_id,
        integer(action, :duration_hours, 2),
        text(action, :reason, context),
        player_name: context.player_name
      )
    end)
  end

  defp execute(%Action{type: :perma_ban_player} = action, context) do
    with_player(context, fn player_id ->
      Crcon.perma_ban(context.server, player_id, text(action, :reason, context),
        player_name: context.player_name
      )
    end)
  end

  defp execute(%Action{type: :switch_player_team}, context) do
    with_player(context, &Crcon.switch_player_now(context.server, &1))
  end

  defp execute(%Action{type: :switch_player_on_death}, context) do
    with_player(context, &Crcon.switch_player_on_death(context.server, &1))
  end

  # ── Flags and watchlist ────────────────────────────────────────────────────

  defp execute(%Action{type: :add_player_flag} = action, context) do
    with_player(context, fn player_id ->
      Crcon.flag_player(context.server, player_id, Action.param(action, :flag),
        player_name: context.player_name,
        comment: text(action, :comment, context)
      )
    end)
  end

  defp execute(%Action{type: :remove_player_flag} = action, context) do
    with_player(context, &Crcon.unflag_player(context.server, &1, Action.param(action, :flag)))
  end

  defp execute(%Action{type: :add_to_watchlist} = action, context) do
    with_player(context, fn player_id ->
      Crcon.watch_player(context.server, player_id, text(action, :reason, context),
        player_name: context.player_name
      )
    end)
  end

  # ── VIP and blacklist ──────────────────────────────────────────────────────

  defp execute(%Action{type: :grant_vip} = action, context) do
    with_player(context, fn player_id ->
      Crcon.add_vip(
        context.server,
        player_id,
        text(action, :description, context),
        expires_in(action, :duration_hours)
      )
    end)
  end

  defp execute(%Action{type: :remove_vip}, context) do
    with_player(context, &Crcon.remove_vip(context.server, &1))
  end

  defp execute(%Action{type: :blacklist_player} = action, context) do
    with_player(context, fn player_id ->
      Crcon.add_blacklist_record(
        context.server,
        player_id,
        integer(action, :blacklist_id, 0),
        text(action, :reason, context),
        expires_at: expires_in(action, :duration_hours),
        admin_name: admin_name()
      )
    end)
  end

  defp execute(%Action{type: :remove_from_watchlist}, context) do
    with_player(context, &Crcon.unwatch_player(context.server, &1))
  end

  # ── Outbound notification ──────────────────────────────────────────────────

  defp execute(%Action{type: :send_discord_webhook} = action, context) do
    with {:ok, _job} <-
           DeliverWebhook.enqueue(
             Action.param(action, :webhook_url),
             text(action, :message, context)
           ) do
      {:ok, :queued}
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  # Every player-scoped action needs somebody to act on. Match-wide triggers
  # can produce a context without a player id, and skipping is the honest
  # outcome there.
  defp with_player(%Context{player_id: nil}, _fun), do: {:skip, "no player in this event"}
  defp with_player(%Context{player_id: player_id}, fun), do: fun.(player_id)

  defp text(action, key, context) do
    action |> Action.param(key) |> Template.render(context)
  end

  defp integer(action, key, default) do
    case Action.param(action, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {int, ""} -> int
          _other -> default
        end

      _other ->
        default
    end
  end

  defp detail(%Action{type: type} = action, context) do
    case type do
      :message_player ->
        text(action, :message, context)

      :message_all_players ->
        text(action, :message, context)

      :broadcast_message ->
        text(action, :message, context)

      :temporary_broadcast ->
        text(action, :message, context)

      :set_welcome_message ->
        text(action, :message, context)

      :punish_player ->
        text(action, :reason, context)

      :kick_player ->
        text(action, :reason, context)

      :perma_ban_player ->
        text(action, :reason, context)

      :add_to_watchlist ->
        text(action, :reason, context)

      :temp_ban_player ->
        "#{integer(action, :duration_hours, 2)}h - #{text(action, :reason, context)}"

      :add_player_flag ->
        to_string(Action.param(action, :flag))

      :remove_player_flag ->
        to_string(Action.param(action, :flag))

      :grant_vip ->
        duration_detail(action, text(action, :description, context))

      :blacklist_player ->
        duration_detail(action, text(action, :reason, context))

      _other ->
        nil
    end
  end

  # "24h - Seeder reward", or just the reason when it never expires.
  defp duration_detail(action, reason) do
    case integer(action, :duration_hours, 0) do
      hours when hours > 0 -> "#{hours}h - #{reason}"
      _indefinite -> reason
    end
  end

  # CRCON stores an absolute expiry, so a duration in hours is resolved here.
  # `0` (or no value at all) means indefinite, which is what both the VIP and
  # the blacklist endpoints treat a missing expiry as.
  defp expires_in(action, key) do
    case integer(action, key, 0) do
      hours when is_integer(hours) and hours > 0 ->
        DateTime.add(DateTime.utc_now(), hours * 60 * 60, :second)

      _indefinite ->
        nil
    end
  end

  # What CRCON's audit log attributes the record to.
  defp admin_name, do: "hll_conditional_actions"
end
