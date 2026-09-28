defmodule HllConditionalActions.Tickets.Listener do
  @moduledoc """
  Turns one server's chat into tickets.

  Runs next to the server's log stream and rule runner, reads the chat lines
  off the stream's topic and hands them to
  `HllConditionalActions.Tickets.handle_chat/4`. The settings are kept in
  memory - chat is the busiest kind of line - and replaced when an admin saves
  new ones.

  It also keeps the last few minutes of chat and kills, so a new ticket can
  carry what happened just before the player called (see
  `HllConditionalActions.Tickets.Context`).

  A failure handling one line is logged and dropped rather than crashing:
  this process shares a `:one_for_all` supervisor with the log stream, and
  one bad line must not reconnect the whole server.
  """

  use GenServer

  require Logger

  alias HllConditionalActions.Crcon.Events.Event
  alias HllConditionalActions.Crcon.LogStream
  alias HllConditionalActions.Tickets
  alias HllConditionalActions.Tickets.Context

  # A hard cap on the window, whatever its time span, so a busy server with
  # a hundred players does not grow it without bound.
  @max_recent 400

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :server))

  @impl GenServer
  def init(server) do
    LogStream.subscribe(server.id)
    Phoenix.PubSub.subscribe(HllConditionalActions.PubSub, Tickets.settings_topic(server.id))

    {:ok, %{server: server, settings: Tickets.get_settings(server.id), recent: []}}
  end

  @impl GenServer
  def handle_info({:crcon_event, %Event{} = event}, state) do
    state = remember(state, event)

    if event.type == :player_chat and state.settings.enabled do
      try do
        Tickets.handle_chat(state.server, state.settings, event, recent: state.recent)
      rescue
        error ->
          Logger.error(
            "[tickets] server #{state.server.id}: could not handle a chat line: " <>
              Exception.format(:error, error, __STACKTRACE__)
          )
      end
    end

    {:noreply, state}
  end

  def handle_info({:ticket_settings_changed, settings}, state),
    do: {:noreply, %{state | settings: settings}}

  def handle_info(_message, state), do: {:noreply, state}

  # Oldest first, trimmed by age and by count.
  defp remember(state, event) do
    if state.settings.enabled and Context.keep?(event) and match?(%DateTime{}, event.occurred_at) do
      since = DateTime.add(event.occurred_at, -Context.window_seconds(), :second)

      recent =
        (state.recent ++ [event])
        |> Enum.drop_while(&(DateTime.compare(&1.occurred_at, since) == :lt))
        |> Enum.take(-@max_recent)

      %{state | recent: recent}
    else
      state
    end
  end
end
