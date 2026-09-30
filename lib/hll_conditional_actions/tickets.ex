defmodule HllConditionalActions.Tickets do
  @moduledoc """
  Tickets: players call an admin from the game chat and admins answer from
  the web.

  ## Flow

    1. A player types one of the server's ticket commands (`!admin help`).
       `HllConditionalActions.Tickets.Listener` sees the chat line and calls
       `handle_chat/2`, which opens a ticket - or adds to the one the player
       already has open - and tells the player it was received.
    2. While the ticket is open, anything else that player says in chat is
       added to it, so the conversation reads like one thread.
    3. An admin answers with `reply/3`; the text goes to the player as a
       private message, prefixed with the admin's name.
    4. The ticket closes by hand (`close/3`) or on its own after the server's
       `auto_close_hours` of silence (`close_stale/0`).

  Who sees what follows the server assignment of each user, like everything
  else: see `HllConditionalActions.Accounts.server_scope/1`.

  Changes are broadcast on `"tickets"` as `{:ticket_changed, ticket}`, so the
  inbox and the ticket page update live.
  """

  use Gettext, backend: HllConditionalActionsWeb.Gettext

  import Ecto.Query

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Accounts.User
  alias HllConditionalActions.Crcon
  alias HllConditionalActions.Crcon.Events.Event
  alias HllConditionalActions.PubSub
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Servers.Server
  alias HllConditionalActions.Tickets.Announcement
  alias HllConditionalActions.Tickets.Context
  alias HllConditionalActions.Tickets.Eligibility
  alias HllConditionalActions.Tickets.Message
  alias HllConditionalActions.Tickets.Reported
  alias HllConditionalActions.Tickets.Settings
  alias HllConditionalActions.Tickets.Ticket

  @topic "tickets"

  # ── PubSub ─────────────────────────────────────────────────────────────────

  @doc "Subscribes the caller to ticket changes on every server."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(PubSub, @topic)

  @doc """
  The topic a server's listener follows for settings changes.
  """
  @spec settings_topic(term()) :: String.t()
  def settings_topic(server_id), do: "tickets:settings:#{server_id}"

  defp broadcast(%Ticket{} = ticket) do
    Phoenix.PubSub.broadcast(PubSub, @topic, {:ticket_changed, ticket})
    ticket
  end

  # ── Settings ───────────────────────────────────────────────────────────────

  @doc """
  A server's settings, or unsaved defaults when it has none (tickets off).
  """
  @spec get_settings(term()) :: Settings.t()
  def get_settings(server_id) do
    Repo.get_by(Settings, server_id: server_id) || %Settings{server_id: server_id}
  end

  @doc "A changeset for the settings form."
  @spec change_settings(Settings.t(), map()) :: Ecto.Changeset.t()
  def change_settings(%Settings{} = settings, attrs \\ %{}),
    do: Settings.changeset(settings, attrs)

  @doc """
  Saves a server's settings and tells its listener.
  """
  @spec save_settings(Settings.t(), map()) :: {:ok, Settings.t()} | {:error, Ecto.Changeset.t()}
  def save_settings(%Settings{} = settings, attrs) do
    settings
    |> Settings.changeset(attrs)
    |> Repo.insert_or_update()
    |> tap(fn
      {:ok, saved} ->
        Phoenix.PubSub.broadcast(
          PubSub,
          settings_topic(saved.server_id),
          {:ticket_settings_changed, saved}
        )

      _error ->
        :ok
    end)
  end

  @doc """
  The text after a ticket command, if the message starts with one.

  The command has to be the first word, so "don't type !admin" does not open
  a ticket. Matching ignores case.

      iex> alias HllConditionalActions.Tickets
      iex> Tickets.match_command("!Admin tk on the bridge", ["!admin", "!adm"])
      {:ok, "tk on the bridge"}
      iex> Tickets.match_command("!adm", ["!admin", "!adm"])
      {:ok, ""}
      iex> Tickets.match_command("!administrator", ["!admin"])
      :nomatch
      iex> Tickets.match_command("please !admin", ["!admin"])
      :nomatch
  """
  @spec match_command(String.t() | nil, [String.t()]) :: {:ok, String.t()} | :nomatch
  def match_command(message, commands) do
    case find_command(message, commands, true) do
      {:ok, _command, text} -> {:ok, text}
      :nomatch -> :nomatch
    end
  end

  @doc """
  Like `match_command/2`, and also says which command it was. With
  `ignore_case` false, `!ADMIN` no longer counts as `!admin`.

      iex> alias HllConditionalActions.Tickets
      iex> Tickets.find_command("!AJUDA tk", ["!admin", "!ajuda"], true)
      {:ok, "!ajuda", "tk"}
      iex> Tickets.find_command("!AJUDA tk", ["!admin", "!ajuda"], false)
      :nomatch
  """
  @spec find_command(String.t() | nil, [String.t()], boolean()) ::
          {:ok, String.t(), String.t()} | :nomatch
  def find_command(nil, _commands, _ignore_case), do: :nomatch

  def find_command(message, commands, ignore_case) do
    [first | rest] = message |> String.trim() |> String.split(~r/\s+/, parts: 2)
    word = if ignore_case == false, do: first, else: String.downcase(first)

    if word in (commands || []),
      do: {:ok, word, rest |> List.first("") |> String.trim()},
      else: :nomatch
  end

  # ── Chat ───────────────────────────────────────────────────────────────────

  @doc """
  Handles a chat line from a server that has tickets on.

  Returns what happened, for the listener's logs and for tests:

    * `{:opened, ticket}` - a command opened a new ticket
    * `{:added, ticket}` - the line joined the player's open ticket
    * `:cooldown` - a command came too soon after the player's last ticket
    * `:rate_limited` - the player hit the server's tickets-per-hour limit
    * `:offline` - outside office hours, on a server that takes no tickets then
    * `:not_allowed` - the player may not open tickets here (see
      `HllConditionalActions.Tickets.Eligibility`)
    * `:duplicate` - the stream delivered this line before
    * `:ignored` - neither a command nor from a player with a ticket
  """
  @spec handle_chat(Server.t(), Settings.t(), Event.t(), keyword()) ::
          {:opened, Ticket.t()}
          | {:added, Ticket.t()}
          | {:status, Ticket.t() | nil}
          | {:closed, Ticket.t() | nil}
          | :cooldown
          | :rate_limited
          | :offline
          | :not_allowed
          | :duplicate
          | :ignored
  def handle_chat(server, settings, event, opts \\ [])

  def handle_chat(%Server{} = server, %Settings{enabled: true} = settings, %Event{} = event, opts)
      when is_binary(event.player_id) and event.player_id != "" do
    log_key = log_key(event)

    if seen?(server.id, log_key) do
      :duplicate
    else
      route_chat(server, settings, event, log_key, opts)
    end
  end

  def handle_chat(_server, _settings, _event, _opts), do: :ignored

  # The player's open tickets, newest first: a line without a command joins
  # the newest; a command opens another while the server allows more than
  # one at a time.
  defp route_chat(server, settings, event, log_key, opts) do
    open = open_tickets(server.id, event.player_id)
    newest = List.first(open)
    room? = length(open) < max_open(settings)

    case find_command(event.chat_message, settings.commands, settings.ignore_case) do
      {:ok, command, text} when text != "" ->
        opts = Keyword.put(opts, :command, command)
        handle_command(server, settings, event, {text, log_key, opts}, {newest, room?})

      {:ok, command, ""} when is_nil(newest) or room? ->
        open_if_allowed(
          server,
          settings,
          event,
          "",
          log_key,
          Keyword.put(opts, :command, command)
        )

      {:ok, _command, ""} ->
        {:added, newest}

      :nomatch when not is_nil(newest) ->
        line = String.trim(event.chat_message || "")
        {:added, add_player_line(newest, event, line, log_key, settings)}

      :nomatch ->
        :ignored
    end
  end

  defp max_open(%Settings{max_open_per_player: max}) when is_integer(max) and max > 1, do: max
  defp max_open(_settings), do: 1

  defp handle_command(server, settings, event, {text, log_key, opts}, {open, room?}) do
    case player_command(text, settings) do
      :status -> {:status, tell_status(server, settings, event, open)}
      :close -> {:closed, close_by_player(open)}
      nil -> command_text(server, settings, event, {text, log_key, opts}, {open, room?})
    end
  end

  defp command_text(server, settings, event, {text, log_key, opts}, {open, room?})
       when is_nil(open) or room?,
       do: open_if_allowed(server, settings, event, text, log_key, opts)

  # Calling again while the ticket is open adds to it, and the player is
  # reminded it is still waiting.
  defp command_text(server, settings, event, {text, log_key, _opts}, {ticket, _room?}) do
    ticket = add_player_line(ticket, event, text, log_key, settings)
    notify_player(server, ticket, settings, already_open_text())
    {:added, ticket}
  end

  @doc false
  def already_open_text,
    do:
      in_default_locale(fn ->
        gettext("You already have ticket \#{ticket_id} open. Wait for the admin's answer.")
      end)

  defp cooldown_text,
    do:
      in_default_locale(fn ->
        gettext("Wait a few minutes before calling an admin again.")
      end)

  defp open_if_allowed(server, settings, event, text, log_key, opts) do
    outside? = not in_hours?(settings, server.timezone, DateTime.utc_now())

    cond do
      cooling_down?(server.id, event.player_id, settings) ->
        refuse(server, settings, event, cooldown_text())
        :cooldown

      over_hourly_limit?(server.id, event.player_id, settings) ->
        :rate_limited

      outside? and settings.accept_offline == false ->
        refuse(server, settings, event, settings.offline_message)
        :offline

      true ->
        case Eligibility.check(server, settings, event.player_id) do
          :ok ->
            opts = Keyword.put(opts, :outside_hours, outside?)
            open_new(server, settings, event, text, log_key, opts)

          {:denied, reason} ->
            refuse(server, settings, event, Eligibility.message(reason, settings))
            :not_allowed
        end
    end
  end

  # Tells a player why no ticket was opened, when there is something to say.
  defp refuse(server, settings, event, text) do
    case String.trim(text || "") do
      "" ->
        :ok

      text ->
        target = %Ticket{player_id: event.player_id, player_name: event.player_name}
        {_delivery, _error} = deliver(server, target, render_notice(text, target, settings))
        :ok
    end
  end

  # `!admin status` / `!admin close`: the whole text is the server's word.
  defp player_command(text, settings) do
    word = String.downcase(text)

    cond do
      present?(settings.status_word) and word == settings.status_word -> :status
      present?(settings.close_word) and word == settings.close_word -> :close
      true -> nil
    end
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp tell_status(server, settings, event, ticket) do
    text = status_text(ticket)
    target = ticket || %Ticket{player_id: event.player_id, player_name: event.player_name}
    {_delivery, _error} = deliver(server, target, render_notice(text, target, settings))
    ticket
  end

  defp status_text(nil),
    do:
      in_default_locale(fn ->
        gettext("You have no open ticket. Type {command} and your message to open one.")
      end)

  defp status_text(%Ticket{status: :answered}),
    do:
      in_default_locale(fn -> gettext("An admin answered your ticket. Keep typing to reply.") end)

  defp status_text(%Ticket{}),
    do: in_default_locale(fn -> gettext("Your ticket is waiting for an admin.") end)

  defp close_by_player(nil), do: nil

  defp close_by_player(ticket) do
    {:ok, ticket} = close(ticket, nil, "player")
    ticket
  end

  @doc """
  Splits a category off the ticket text: the category's name at the start
  (ignoring case, the longest name that fits), or its number in the list the
  player was shown ("2 he keeps team killing").

      iex> alias HllConditionalActions.Tickets
      iex> settings = %HllConditionalActions.Tickets.Settings{category_priorities: %{"tk" => "high", "cheat" => "urgent", "Tiro amigo" => "high"}, category_order: ["cheat", "tk", "Tiro amigo"]}
      iex> Tickets.split_category("Cheat aimbot on the hill", settings)
      {"cheat", "aimbot on the hill"}
      iex> Tickets.split_category("tiro amigo no tanque", settings)
      {"Tiro amigo", "no tanque"}
      iex> Tickets.split_category("2 on the bridge", settings)
      {"tk", "on the bridge"}
      iex> Tickets.split_category("help me", settings)
      {nil, "help me"}
  """
  @spec split_category(String.t(), Settings.t()) :: {String.t() | nil, String.t()}
  def split_category(text, %Settings{} = settings) do
    categories = Settings.categories(settings)
    lower = String.downcase(text)

    named =
      categories
      |> Enum.sort_by(&(-String.length(&1)))
      |> Enum.find(fn name ->
        name = String.downcase(name)
        lower == name or String.starts_with?(lower, name <> " ")
      end)

    cond do
      named ->
        {named, text |> String.slice(String.length(named)..-1//1) |> String.trim()}

      numbered = numbered_category(text, categories) ->
        [_number | rest] = String.split(text, ~r/\s+/, parts: 2)
        {numbered, rest |> List.first("") |> String.trim()}

      true ->
        {nil, text}
    end
  end

  # "2" or "2 the rest": the second category of the list the player was shown.
  defp numbered_category(text, categories) do
    with [first | _rest] <- String.split(text, ~r/\s+/, parts: 2),
         {number, ""} <- Integer.parse(first),
         true <- number >= 1 do
      Enum.at(categories, number - 1)
    else
      _other -> nil
    end
  end

  @doc """
  The categories as the player reads them in game: "1 tk, 2 cheat".

      iex> alias HllConditionalActions.Tickets
      iex> Tickets.category_menu(%HllConditionalActions.Tickets.Settings{category_priorities: %{"tk" => "high", "cheat" => "urgent"}, category_order: ["tk", "cheat"]})
      "1 tk, 2 cheat"
  """
  @spec category_menu(Settings.t()) :: String.t()
  def category_menu(%Settings{} = settings) do
    settings
    |> Settings.categories()
    |> Enum.with_index(1)
    |> Enum.map_join(", ", fn {name, index} -> "#{index} #{name}" end)
  end

  @doc """
  Whether a moment falls inside the server's office hours. Always true when
  the server has none. A window that ends before it starts runs past
  midnight (20:00 to 02:00), and several windows a day are fine.

      iex> alias HllConditionalActions.Tickets
      iex> settings = %HllConditionalActions.Tickets.Settings{hours_enabled: true, hours_start: ~T[20:00:00], hours_end: ~T[02:00:00], hours_days: [1, 2, 3, 4, 5, 6, 7]}
      iex> Tickets.in_hours?(settings, "Etc/UTC", ~U[2026-09-26 23:00:00Z])
      true
      iex> Tickets.in_hours?(settings, "Etc/UTC", ~U[2026-09-26 12:00:00Z])
      false
      iex> ranges = %HllConditionalActions.Tickets.Settings{hours_enabled: true, hours_ranges: %{"3" => [["12:00", "14:00"], ["19:00", "24:00"]]}}
      iex> {Tickets.in_hours?(ranges, "Etc/UTC", ~U[2026-09-30 13:00:00Z]), Tickets.in_hours?(ranges, "Etc/UTC", ~U[2026-09-30 16:00:00Z])}
      {true, false}
  """
  @spec in_hours?(Settings.t(), String.t() | nil, DateTime.t()) :: boolean()
  def in_hours?(%Settings{hours_enabled: true} = settings, timezone, %DateTime{} = at) do
    case Settings.schedule(settings) do
      schedule when map_size(schedule) == 0 ->
        true

      schedule ->
        local =
          case DateTime.shift_zone(at, timezone || "Etc/UTC") do
            {:ok, local} -> local
            {:error, _reason} -> at
          end

        minute = local.hour * 60 + local.minute

        schedule
        |> Map.get(Date.day_of_week(local), [])
        |> Enum.any?(fn {start, stop} -> minute >= start and minute < stop end)
    end
  end

  def in_hours?(_settings, _timezone, _at), do: true

  @doc """
  What identifies a chat line across a stream reconnect: the stream's own id
  when the line carries it, otherwise the game time, player and text.

      iex> alias HllConditionalActions.Tickets
      iex> alias HllConditionalActions.Crcon.Events.Event
      iex> event = %Event{type: :player_chat, action: "CHAT", occurred_at: nil, raw: %{"stream_id" => "1790-0"}}
      iex> Tickets.log_key(event)
      "1790-0"
      iex> Tickets.log_key(%{event | raw: %{}})
      nil
  """
  @spec log_key(Event.t()) :: String.t() | nil
  def log_key(%Event{raw: %{"stream_id" => id}}) when is_binary(id) and id != "", do: id

  def log_key(%Event{raw: %{"timestamp_ms" => ms}} = event) when is_integer(ms),
    do: "#{ms}:#{event.player_id}:#{event.chat_message}"

  def log_key(_event), do: nil

  defp seen?(_server_id, nil), do: false

  defp seen?(server_id, log_key) do
    Repo.exists?(
      from m in Message,
        join: t in assoc(m, :ticket),
        where: m.log_key == ^log_key and t.server_id == ^server_id
    )
  end

  # The player's tickets still open on the server, newest first.
  defp open_tickets(server_id, player_id) do
    Repo.all(
      from t in Ticket,
        where: t.server_id == ^server_id and t.player_id == ^player_id and t.status != :closed,
        order_by: [desc: t.inserted_at, desc: t.id]
    )
  end

  defp open_ticket(server_id, player_id),
    do: server_id |> open_tickets(player_id) |> List.first()

  defp cooling_down?(_server_id, _player_id, %Settings{cooldown_seconds: seconds})
       when seconds in [nil, 0],
       do: false

  defp cooling_down?(server_id, player_id, %Settings{cooldown_seconds: seconds}),
    do: opened_since(server_id, player_id, seconds) > 0

  defp over_hourly_limit?(_server_id, _player_id, %Settings{max_per_hour: max})
       when max in [nil, 0],
       do: false

  defp over_hourly_limit?(server_id, player_id, %Settings{max_per_hour: max}),
    do: opened_since(server_id, player_id, 3600) >= max

  # Tickets the player opened themselves; rule-opened ones do not count
  # against them.
  defp opened_since(server_id, player_id, seconds) do
    since = DateTime.add(DateTime.utc_now(), -seconds, :second)

    Repo.aggregate(
      from(t in Ticket,
        where:
          t.server_id == ^server_id and t.player_id == ^player_id and t.source == :chat and
            t.inserted_at > ^since
      ),
      :count
    )
  end

  defp open_new(server, settings, event, text, log_key, opts) do
    {category, text} = split_category(text, settings)
    recent = Keyword.get(opts, :recent, [])
    context = Context.capture(recent, event)
    reported = Reported.detect(context, event, text, recent)

    # A bare command still says something: keep what the player typed.
    body = if text == "", do: String.trim(event.chat_message), else: text

    attrs = %{
      server_id: server.id,
      player_id: event.player_id,
      player_name: event.player_name,
      source: :chat,
      category: category,
      priority: priority_for(category, settings),
      context: context,
      opened_with: Keyword.get(opts, :command),
      outside_hours: Keyword.get(opts, :outside_hours, false),
      reported_player_id: reported && reported.id,
      reported_player_name: reported && reported.name
    }

    case insert_ticket(attrs, %{author: :player, body: body, log_key: log_key},
           max_open: max_open(settings)
         ) do
      {:ok, ticket} ->
        opened(server, settings, ticket, text, body, attrs.outside_hours)

      # Another line from the same player won the race; join that ticket.
      {:error, _reason} ->
        join_open(server, settings, event, text, log_key)
    end
  end

  defp opened(server, settings, ticket, text, body, outside_hours) do
    notify_player(server, ticket, settings, greeting(settings, outside_hours))

    if text == "" and settings.ask_reason,
      do: notify_player(server, ticket, settings, ask_reason_text())

    ticket = announce(server, settings, ticket, body)
    Phoenix.PubSub.broadcast(PubSub, @topic, {:ticket_opened, ticket})
    {:opened, broadcast(ticket)}
  end

  defp join_open(server, settings, event, text, log_key) do
    case open_ticket(server.id, event.player_id) do
      nil -> :ignored
      ticket -> {:added, add_player_line(ticket, event, text, log_key, settings)}
    end
  end

  defp ask_reason_text,
    do:
      in_default_locale(fn ->
        gettext("Tell us what happened: type it here in the chat and it joins your ticket.")
      end)

  @doc """
  The priority a new ticket opens with: its category's, or the server's
  default when it has none.

      iex> alias HllConditionalActions.Tickets
      iex> settings = %HllConditionalActions.Tickets.Settings{category_priorities: %{"cheat" => "urgent"}, default_priority: "low"}
      iex> {Tickets.priority_for("cheat", settings), Tickets.priority_for(nil, settings)}
      {:urgent, :low}
  """
  @spec priority_for(String.t() | nil, Settings.t()) :: atom()
  def priority_for(nil, settings), do: Ticket.parse_priority(settings.default_priority)

  def priority_for(category, settings) do
    name = Settings.find_category(settings, category)

    Ticket.parse_priority(
      Map.get(settings.category_priorities || %{}, name, settings.default_priority)
    )
  end

  # Outside office hours the player is told nobody is around.
  defp greeting(settings, false), do: settings.received_message
  defp greeting(settings, true), do: settings.offline_message || settings.received_message

  # Opening is serialised per player, so two lines racing each other cannot
  # open more tickets than the server allows at once.
  defp insert_ticket(attrs, first_message, opts \\ []) do
    max = Keyword.get(opts, :max_open)

    Repo.transaction(fn ->
      if max, do: ensure_room(attrs, max)

      with {:ok, ticket} <-
             %Ticket{}
             |> Ticket.open_changeset(Map.put(attrs, :last_activity_at, now()))
             |> Repo.insert(),
           {:ok, _message} <- insert_message(ticket, first_message) do
        ticket
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp ensure_room(attrs, max) do
    lock = :erlang.phash2({:ticket_open, attrs.server_id, attrs.player_id})
    Repo.query!("SELECT pg_advisory_xact_lock($1)", [lock])

    if length(open_tickets(attrs.server_id, attrs.player_id)) >= max,
      do: Repo.rollback(:full)
  end

  defp add_player_line(ticket, _event, "", _log_key, _settings), do: ticket

  defp add_player_line(ticket, event, text, log_key, settings) do
    case insert_message(ticket, %{author: :player, body: text, log_key: log_key}) do
      {:ok, _message} ->
        ticket
        |> Ticket.update_changeset(
          %{
            status: :open,
            player_name: event.player_name || ticket.player_name,
            last_activity_at: now()
          }
          |> Map.merge(picked_category(ticket, text, settings))
        )
        |> Repo.update!()
        |> broadcast()

      # The same line twice at once: the first one already counted.
      {:error, _changeset} ->
        ticket
    end
  end

  # A ticket without a category takes one when the player answers with its
  # number (or its name) alone.
  defp picked_category(%Ticket{category: nil} = ticket, text, %Settings{} = settings) do
    case split_category(text, settings) do
      {category, ""} when is_binary(category) ->
        priority = priority_for(category, settings)

        if Ticket.rank(priority) > Ticket.rank(ticket.priority),
          do: %{category: category, priority: priority},
          else: %{category: category}

      _other ->
        %{}
    end
  end

  defp picked_category(_ticket, _text, _settings), do: %{}

  # ── Rules ──────────────────────────────────────────────────────────────────

  @doc """
  Opens a ticket for admins to look at, on behalf of a rule - three team
  kills in five minutes, a slur in chat. Works whether or not tickets are on
  for the server, since the rule's owner asked for it.

  If the player already has a ticket open, the note joins it instead, and a
  rule with a higher priority raises the ticket to it (never lowers it). The player is not told: this is
  a note for admins, not a conversation they started.
  """
  @spec open_from_rule(Server.t(), map(), keyword()) ::
          {:opened, Ticket.t()} | {:added, Ticket.t()} | {:error, term()}
  def open_from_rule(%Server{} = server, %{player_id: player_id} = player, opts)
      when is_binary(player_id) and player_id != "" do
    note = String.trim(Keyword.get(opts, :note) || "")
    note = if note == "", do: Keyword.get(opts, :rule_name) || "Rule", else: note
    priority = Ticket.parse_priority(Keyword.get(opts, :priority, :normal))

    case open_ticket(server.id, player_id) do
      nil ->
        attrs = %{
          server_id: server.id,
          player_id: player_id,
          player_name: Map.get(player, :player_name),
          source: :rule,
          rule_id: Keyword.get(opts, :rule_id),
          priority: priority
        }

        with {:ok, ticket} <- insert_ticket(attrs, %{author: :system, body: note}) do
          ticket = announce(server, get_settings(server.id), ticket, note)
          Phoenix.PubSub.broadcast(PubSub, @topic, {:ticket_opened, ticket})
          {:opened, broadcast(ticket)}
        end

      ticket ->
        {:ok, _message} = insert_message(ticket, %{author: :system, body: note})

        changes = %{status: :open, last_activity_at: now()}

        changes =
          if Ticket.rank(priority) > Ticket.rank(ticket.priority),
            do: Map.put(changes, :priority, priority),
            else: changes

        {:added, ticket |> Ticket.update_changeset(changes) |> Repo.update!() |> broadcast()}
    end
  end

  def open_from_rule(_server, _player, _opts), do: {:error, :no_player}

  # Announces a new ticket on Discord and notes when, for the settings page.
  # Outside office hours only urgent tickets go out, and only when the
  # server asks for it.
  defp announce(server, settings, ticket, text) do
    if settings.discord_webhook_id && announce?(server, settings, ticket) do
      :ok = Announcement.new_ticket(server, settings, ticket, text)

      ticket
      |> Ticket.update_changeset(%{announced_at: now()})
      |> Repo.update!()
    else
      ticket
    end
  end

  defp announce?(server, settings, ticket) do
    outside? =
      ticket.outside_hours or
        (ticket.source == :rule and not in_hours?(settings, server.timezone, DateTime.utc_now()))

    cond do
      not settings.hours_enabled -> true
      not outside? -> true
      true -> ticket.priority == :urgent and settings.offline_alert_urgent != false
    end
  end

  # ── Admin actions ──────────────────────────────────────────────────────────

  @doc """
  Sends an admin's answer to the player and records it.

  The line is stored even if CRCON refuses it - the player may have left -
  with the delivery outcome, so the admin sees it did not arrive.
  """
  @spec reply(Ticket.t(), User.t(), String.t(), keyword()) ::
          {:ok, Message.t()} | {:error, :closed | :empty | Ecto.Changeset.t()}
  def reply(ticket, user, body, opts \\ [])

  def reply(%Ticket{status: :closed}, _user, _body, _opts), do: {:error, :closed}

  # `quick_reply:` names the quick reply the answer started from, so each
  # one counts how often it is used.
  def reply(%Ticket{} = ticket, %User{} = user, body, opts) do
    case String.trim(body || "") do
      "" ->
        {:error, :empty}

      text ->
        server = Repo.get!(Server, ticket.server_id)
        settings = get_settings(ticket.server_id)

        {delivery, error} =
          deliver(server, ticket, in_game_reply(settings, user, text, ticket, server))

        with {:ok, message} <-
               insert_message(ticket, %{
                 author: :admin,
                 user_id: user.id,
                 body: text,
                 delivery: delivery,
                 delivery_error: error,
                 quick_reply: Keyword.get(opts, :quick_reply)
               }) do
          ticket
          |> Ticket.update_changeset(%{
            status: :answered,
            last_activity_at: now(),
            first_response_at: ticket.first_response_at || now(),
            assigned_to_id: ticket.assigned_to_id || user.id
          })
          |> Repo.update!()
          |> broadcast()

          {:ok, message}
        end
    end
  end

  @doc """
  What the player reads for an admin's answer: the server's prefix, with
  `{admin}` replaced by the admin's name, then the text.

      iex> alias HllConditionalActions.Tickets
      iex> settings = %HllConditionalActions.Tickets.Settings{reply_prefix: "[ADMIN {admin}]"}
      iex> Tickets.in_game_reply(settings, %{name: "Ana", username: "ana"}, "On my way")
      "[ADMIN Ana] On my way"
      iex> Tickets.in_game_reply(%HllConditionalActions.Tickets.Settings{}, %{name: nil, username: "ana"}, "Hi")
      "Hi"
  """
  @spec in_game_reply(Settings.t(), map(), String.t(), map() | nil, map() | nil) :: String.t()
  def in_game_reply(
        %Settings{reply_prefix: prefix} = settings,
        user,
        text,
        ticket \\ nil,
        server \\ nil
      ) do
    vars = %{
      "admin" => admin_name(user),
      "admin_name" => admin_name(user),
      "message" => text
    }

    case String.trim(prefix || "") do
      "" ->
        text

      prefix ->
        filled = fill(prefix, notice_vars(ticket || %{}, settings, server) |> Map.merge(vars))
        if String.contains?(prefix, "{message}"), do: filled, else: filled <> " " <> text
    end
  end

  defp admin_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp admin_name(%{username: username}), do: username

  @doc """
  Closes a ticket and tells the player. `user` is nil when the system closes
  it for inactivity.
  """
  @spec close(Ticket.t(), User.t() | nil, String.t() | nil) :: {:ok, Ticket.t()}
  def close(ticket, user, reason \\ nil)

  def close(%Ticket{status: :closed} = ticket, _user, _reason), do: {:ok, ticket}

  def close(%Ticket{} = ticket, user, reason) do
    server = Repo.get!(Server, ticket.server_id)
    settings = get_settings(ticket.server_id)

    notify_player(server, ticket, settings, settings.closed_message)

    ticket =
      ticket
      |> Ticket.update_changeset(%{
        status: :closed,
        closed_at: now(),
        closed_by_id: user && user.id,
        close_reason: reason
      })
      |> Repo.update!()
      |> broadcast()

    {:ok, ticket}
  end

  @doc """
  Reopens a closed ticket. Fails if the player already opened a new one.
  """
  @spec reopen(Ticket.t()) :: {:ok, Ticket.t()} | {:error, :full | Ecto.Changeset.t()}
  def reopen(%Ticket{} = ticket) do
    settings = get_settings(ticket.server_id)

    if length(open_tickets(ticket.server_id, ticket.player_id)) >= max_open(settings) do
      {:error, :full}
    else
      ticket
      |> Ticket.update_changeset(%{
        status: :open,
        closed_at: nil,
        closed_by_id: nil,
        close_reason: nil,
        last_activity_at: now()
      })
      |> Repo.update()
      |> tap_ok(&broadcast/1)
    end
  end

  @doc """
  Sets the player a ticket is about (the one being reported), or clears it
  with a nil id.
  """
  @spec set_reported(Ticket.t(), String.t() | nil, String.t() | nil) ::
          {:ok, Ticket.t()} | {:error, Ecto.Changeset.t()}
  def set_reported(%Ticket{} = ticket, player_id, name) do
    id = if is_binary(player_id), do: String.trim(player_id)
    id = if id in [nil, ""], do: nil, else: id

    ticket
    |> Ticket.update_changeset(%{
      reported_player_id: id,
      reported_player_name: id && (blank_to_nil(name) || id)
    })
    |> Repo.update()
    |> tap_ok(&broadcast/1)
  end

  @doc """
  Works out, once, who an older ticket is about, from the names in its
  context (see `HllConditionalActions.Tickets.Reported.infer/1`), and keeps
  it. The ticket as it is when nothing is sure.
  """
  @spec infer_reported(Ticket.t()) :: Ticket.t()
  def infer_reported(%Ticket{reported_player_id: nil, source: :chat, context: [_ | _]} = ticket) do
    case Reported.infer(ticket) do
      %{id: id, name: name} ->
        case set_reported(ticket, id, name) do
          {:ok, updated} ->
            %{
              ticket
              | reported_player_id: updated.reported_player_id,
                reported_player_name: updated.reported_player_name
            }

          {:error, _changeset} ->
            ticket
        end

      nil ->
        ticket
    end
  end

  def infer_reported(ticket), do: ticket

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      text -> text
    end
  end

  @doc "Changes a ticket's priority."
  @spec set_priority(Ticket.t(), atom()) :: {:ok, Ticket.t()}
  def set_priority(%Ticket{} = ticket, priority) do
    priority = Ticket.parse_priority(priority)

    ticket
    |> Ticket.update_changeset(%{priority: priority})
    |> Repo.update()
    |> tap_ok(&broadcast/1)
  end

  @doc """
  Assigns a ticket to a user, or unassigns it with nil. `by` is who did it:
  when somebody hands a ticket to someone else, the new owner is told
  (`{:ticket_assigned, ticket, user_id, by_name}` on the tickets topic).
  """
  @spec assign(Ticket.t(), User.t() | nil, User.t() | nil) :: {:ok, Ticket.t()}
  def assign(%Ticket{} = ticket, user, by \\ nil) do
    ticket
    |> Ticket.update_changeset(%{assigned_to_id: user && user.id})
    |> Repo.update()
    |> tap_ok(fn updated ->
      broadcast(updated)

      if user && by && user.id != by.id do
        Phoenix.PubSub.broadcast(
          PubSub,
          @topic,
          {:ticket_assigned, updated, user.id, admin_name(by)}
        )
      end
    end)
  end

  @doc """
  Who a ticket can be handed to: active users who may answer tickets and
  reach its server.
  """
  @spec assignable_users(Ticket.t()) :: [User.t()]
  def assignable_users(%Ticket{} = ticket) do
    Accounts.list_users()
    |> Repo.preload([:role, :servers])
    |> Enum.filter(
      &(&1.active and Accounts.can?(&1, :manage_tickets) and
          Accounts.can_access_server?(&1, ticket.server_id))
    )
    |> Enum.sort_by(&String.downcase(admin_name(&1)))
  end

  @doc """
  Adds an internal note: kept with the ticket for the other admins, never
  sent to the player.
  """
  @spec add_note(Ticket.t(), User.t(), String.t()) ::
          {:ok, Message.t()} | {:error, :empty | Ecto.Changeset.t()}
  def add_note(%Ticket{} = ticket, %User{} = user, body) do
    case String.trim(body || "") do
      "" ->
        {:error, :empty}

      text ->
        with {:ok, message} <-
               insert_message(ticket, %{author: :note, user_id: user.id, body: text}) do
          broadcast(ticket)
          {:ok, message}
        end
    end
  end

  @doc """
  The ticket as plain text, for a report or a ban appeal. Internal notes are
  left out unless `notes: true`.
  """
  @spec transcript(Ticket.t(), keyword()) :: String.t()
  def transcript(%Ticket{} = ticket, opts \\ []) do
    notes? = Keyword.get(opts, :notes, false)

    header = [
      "Ticket ##{ticket.id} - #{ticket.server.name}",
      "Player: #{ticket.player_name || "?"} (#{ticket.player_id})",
      "Opened: #{format_at(ticket.inserted_at)}",
      "Status: #{ticket.status}" <> if(ticket.category, do: " - #{ticket.category}", else: "")
    ]

    context =
      if ticket.context == [],
        do: [],
        else: ["", "Before the call:"] ++ Enum.map(ticket.context, &"  #{&1["at"]} #{&1["text"]}")

    lines =
      for message <- ticket.messages, notes? or message.author != :note do
        "[#{format_at(message.inserted_at)}] #{transcript_author(message, ticket)}: #{message.body}"
      end

    Enum.join(header ++ context ++ ["", "Conversation:"] ++ lines, "\n") <> "\n"
  end

  defp transcript_author(%{author: :player}, ticket), do: ticket.player_name || ticket.player_id

  defp transcript_author(%{author: :admin, user: %{} = user}, _ticket),
    do: "ADMIN " <> admin_name(user)

  defp transcript_author(%{author: :note, user: %{} = user}, _ticket),
    do: "NOTE " <> admin_name(user)

  defp transcript_author(%{author: author}, _ticket), do: String.upcase(to_string(author))

  defp format_at(at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M:%S UTC")

  @doc """
  The CRCON actions an admin can take from a ticket.
  """
  @spec player_actions() :: [atom()]
  def player_actions, do: [:message, :punish, :kick, :watch, :temp_ban]

  @doc """
  Runs a CRCON action on the ticket's player - or on another player the
  ticket is about, when `target_id` is given (the one being reported) - and
  records it in the conversation, so the next admin sees what was done.

  Acting on a player needs `:manage_players`; answering the ticket alone
  does not grant it.
  """
  @spec act(Ticket.t(), User.t(), atom(), String.t(), String.t() | nil, keyword()) ::
          {:ok, Message.t()}
          | {:error, :forbidden | :empty_reason | :unknown_action | :bad_duration | String.t()}
  def act(%Ticket{} = ticket, %User{} = user, action, reason, target_id \\ nil, opts \\ []) do
    hours = Keyword.get(opts, :duration_hours, 2)
    reason = String.trim(reason || "")
    target = if blank?(target_id), do: ticket.player_id, else: String.trim(target_id)

    with :ok <- check_action(user, action, reason, hours) do
      server = Repo.get!(Server, ticket.server_id)

      # A message goes as written; a penalty is signed, as the player sees it.
      text = if action == :message, do: reason, else: "#{reason} - #{admin_name(user)}"

      case run_player_action(server, action, target, text, hours) do
        {:ok, _result} ->
          {:ok, message} =
            insert_message(ticket, %{
              author: :system,
              user_id: user.id,
              body: "#{action_note(action, hours)} #{target_label(ticket, target)}: #{reason}"
            })

          ticket
          |> Ticket.update_changeset(%{last_activity_at: now()})
          |> Repo.update!()
          |> broadcast()

          {:ok, message}

        {:error, error} ->
          {:error, Exception.message(error)}
      end
    end
  end

  defp check_action(user, action, reason, hours) do
    cond do
      action not in player_actions() -> {:error, :unknown_action}
      not Accounts.can?(user, :manage_players) -> {:error, :forbidden}
      reason == "" -> {:error, :empty_reason}
      action == :temp_ban and not valid_hours?(hours) -> {:error, :bad_duration}
      true -> :ok
    end
  end

  defp valid_hours?(hours), do: is_integer(hours) and hours in 1..8760

  defp run_player_action(server, :message, player_id, text, _hours),
    do: Crcon.message_player(server, player_id, text)

  defp run_player_action(server, :punish, player_id, reason, _hours),
    do: Crcon.punish(server, player_id, reason)

  defp run_player_action(server, :kick, player_id, reason, _hours),
    do: Crcon.kick(server, player_id, reason)

  defp run_player_action(server, :watch, player_id, reason, _hours),
    do: Crcon.watch_player(server, player_id, reason)

  defp run_player_action(server, :temp_ban, player_id, reason, hours),
    do: Crcon.temp_ban(server, player_id, hours, reason)

  # Stored as data, read by admins of any language: kept as CRCON's own verbs.
  defp action_note(:message, _hours), do: "MESSAGE"
  defp action_note(:punish, _hours), do: "PUNISH"
  defp action_note(:kick, _hours), do: "KICK"
  defp action_note(:watch, _hours), do: "WATCHLIST"
  defp action_note(:temp_ban, hours), do: "TEMPBAN #{hours}h"

  defp target_label(%Ticket{player_id: id} = ticket, id), do: ticket.player_name || id

  defp target_label(%Ticket{reported_player_id: id} = ticket, id),
    do: ticket.reported_player_name || id

  defp target_label(_ticket, target), do: target

  defp blank?(value), do: String.trim(value || "") == ""

  @doc """
  Closes every ticket silent for longer than its server's `auto_close_hours`.
  Servers with 0 keep tickets open until somebody closes them.
  Returns how many were closed.
  """
  @spec close_stale() :: non_neg_integer()
  def close_stale do
    now = now()
    warn_before_close(now)

    stale =
      Repo.all(
        from t in Ticket,
          join: s in Settings,
          on: s.server_id == t.server_id,
          where: t.status != :closed and s.auto_close_hours > 0,
          where:
            t.last_activity_at <
              fragment("?::timestamp - make_interval(hours => ?)", ^now, s.auto_close_hours)
      )

    Enum.each(stale, &close(&1, nil, "inactivity"))
    length(stale)
  end

  # An hour before a silent ticket closes on its own, the player is told, on
  # the servers that ask for it - once per silence.
  defp warn_before_close(now) do
    due =
      Repo.all(
        from t in Ticket,
          join: s in Settings,
          on: s.server_id == t.server_id,
          where: t.status != :closed and s.warn_before_close and s.auto_close_hours > 1,
          where:
            t.last_activity_at <
              fragment("?::timestamp - make_interval(hours => ?)", ^now, s.auto_close_hours - 1),
          where: is_nil(t.close_warned_at) or t.close_warned_at < t.last_activity_at
      )

    Enum.each(due, fn ticket ->
      server = Repo.get!(Server, ticket.server_id)
      settings = get_settings(ticket.server_id)
      notify_player(server, ticket, settings, close_warning_text())

      ticket |> Ticket.update_changeset(%{close_warned_at: now}) |> Repo.update!()
    end)
  end

  defp close_warning_text,
    do:
      in_default_locale(fn ->
        gettext(
          "Your ticket \#{ticket_id} closes in 1 hour without news. Write here if you still need help."
        )
      end)

  # ── Queries ────────────────────────────────────────────────────────────────

  @doc """
  Tickets a user may see, newest activity first.

  Filters: `:server_id`, `:status` (`:active` for anything not closed),
  `:limit`.
  """
  @spec list_tickets(User.t(), keyword()) :: [Ticket.t()]
  def list_tickets(user, filters \\ []) do
    user
    |> scoped()
    |> filter(filters)
    |> order_by([t],
      desc:
        fragment(
          "CASE ? WHEN 'urgent' THEN 3 WHEN 'high' THEN 2 WHEN 'normal' THEN 1 ELSE 0 END",
          t.priority
        ),
      desc: t.last_activity_at,
      desc: t.id
    )
    |> limit(^Keyword.get(filters, :limit, 200))
    |> preload([:server, :assigned_to, :messages])
    |> Repo.all()
  end

  @doc """
  How many tickets wait on an admin (status `:open`), per server id.
  """
  @spec open_counts(User.t()) :: %{term() => non_neg_integer()}
  def open_counts(user) do
    user
    |> scoped()
    |> where([t], t.status == :open)
    |> group_by([t], t.server_id)
    |> select([t], {t.server_id, count(t.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  A ticket with its conversation, if the user may see its server.
  """
  @spec fetch_ticket(User.t(), term()) :: {:ok, Ticket.t()} | :error
  def fetch_ticket(user, id) do
    query =
      from t in scoped(user),
        where: t.id == ^id,
        preload: [:server, :assigned_to, :closed_by, :rule, messages: :user]

    case Repo.one(query) do
      nil -> :error
      ticket -> {:ok, ticket}
    end
  end

  @doc "The player's earlier tickets on any server, newest first."
  @spec player_history(User.t(), Ticket.t()) :: [Ticket.t()]
  def player_history(user, %Ticket{} = ticket) do
    user
    |> scoped()
    |> where([t], t.player_id == ^ticket.player_id and t.id != ^ticket.id)
    |> order_by([t], desc: t.inserted_at)
    |> limit(10)
    |> preload(:server)
    |> Repo.all()
  end

  @doc """
  How many tickets each of these players opened, on the servers the user
  sees - to spot who calls an admin for everything.
  """
  @spec counts_by_player(User.t(), [String.t()]) :: %{String.t() => non_neg_integer()}
  def counts_by_player(_user, []), do: %{}

  def counts_by_player(user, player_ids) do
    user
    |> scoped()
    |> where([t], t.player_id in ^Enum.uniq(player_ids))
    |> group_by([t], t.player_id)
    |> select([t], {t.player_id, count(t.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  How many tickets a player opened over time, on the servers the user sees.
  """
  @spec player_ticket_count(User.t(), String.t()) :: non_neg_integer()
  def player_ticket_count(user, player_id) do
    user |> scoped() |> where([t], t.player_id == ^player_id) |> Repo.aggregate(:count)
  end

  @doc """
  Tickets waiting on an admin for longer than their server's
  `attention_minutes`, oldest first. Servers with 0 never show here.
  """
  @spec overdue([term()]) :: [Ticket.t()]
  def overdue([]), do: []

  def overdue(server_ids) do
    now = now()

    Repo.all(
      from t in Ticket,
        join: s in Settings,
        on: s.server_id == t.server_id,
        where: t.server_id in ^server_ids and t.status == :open and s.attention_minutes > 0,
        where:
          t.last_activity_at <
            fragment("?::timestamp - make_interval(mins => ?)", ^now, s.attention_minutes),
        order_by: [asc: t.last_activity_at],
        preload: :server
    )
  end

  @doc """
  Numbers for the metrics page, over the last `:days` (default 7) and
  optionally one `:server_id`:

    * `:opened`, `:closed`, `:open_now`
    * `:median_response_seconds` / `:average_response_seconds` - from a
      player opening a ticket to the first admin answer
    * `:by_server` - `[{server_name, count}]`
    * `:by_admin` - `[{admin_name, answers, tickets}]`
    * `:by_hour` - 24 counts of opened tickets per hour of the day, in the
      `:timezone` given (default UTC)
    * `:top_players` - the players who opened the most tickets
  """
  @spec metrics(User.t(), keyword()) :: map()
  def metrics(user, opts \\ []) do
    days = Keyword.get(opts, :days, 7)
    since = DateTime.add(now(), -days, :day)
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")

    base =
      user
      |> scoped()
      |> filter(server_id: Keyword.get(opts, :server_id))
      |> where([t], t.inserted_at >= ^since)

    response_times =
      base
      |> where([t], not is_nil(t.first_response_at) and t.source == :chat)
      |> select([t], fragment("EXTRACT(EPOCH FROM (? - ?))", t.first_response_at, t.inserted_at))
      |> Repo.all()
      |> Enum.map(&to_float/1)
      |> Enum.sort()

    # A week of tickets is small enough to bucket here, which keeps time zone
    # rules in one place (the app's Tz database) instead of in SQL.
    by_hour =
      base
      |> select([t], t.inserted_at)
      |> Repo.all()
      |> Enum.frequencies_by(&local_hour(&1, timezone))

    %{
      days: days,
      opened: Repo.aggregate(base, :count),
      closed: base |> where([t], t.status == :closed) |> Repo.aggregate(:count),
      open_now:
        user
        |> scoped()
        |> filter(server_id: Keyword.get(opts, :server_id))
        |> where([t], t.status != :closed)
        |> Repo.aggregate(:count),
      median_response_seconds: median(response_times),
      average_response_seconds: average(response_times),
      answered: length(response_times),
      by_server:
        base
        |> join(:inner, [t], s in assoc(t, :server))
        |> group_by([_t, s], s.name)
        |> select([t, s], {s.name, count(t.id)})
        |> order_by([t], desc: count(t.id))
        |> Repo.all(),
      by_admin: by_admin(base),
      by_hour: Enum.map(0..23, &Map.get(by_hour, &1, 0)),
      top_players:
        base
        |> group_by([t], t.player_id)
        |> select([t], {t.player_id, max(t.player_name), count(t.id)})
        |> order_by([t], desc: count(t.id))
        |> limit(10)
        |> Repo.all()
    }
  end

  defp by_admin(base) do
    ticket_ids = select(base, [t], t.id)

    Repo.all(
      from m in Message,
        join: u in assoc(m, :user),
        where: m.author == :admin and m.ticket_id in subquery(ticket_ids),
        group_by: [u.id, u.name, u.username],
        select: {coalesce(u.name, u.username), count(m.id), count(m.ticket_id, :distinct)},
        order_by: [desc: count(m.id)]
    )
  end

  defp local_hour(at, timezone) do
    case DateTime.shift_zone(at, timezone) do
      {:ok, local} -> local.hour
      {:error, _reason} -> at.hour
    end
  end

  defp median([]), do: nil

  defp median(sorted) do
    middle = div(length(sorted), 2)

    if rem(length(sorted), 2) == 1,
      do: Enum.at(sorted, middle),
      else: (Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2
  end

  defp average([]), do: nil
  defp average(values), do: Enum.sum(values) / length(values)

  defp to_float(%Decimal{} = value), do: Decimal.to_float(value)
  defp to_float(value) when is_number(value), do: value / 1

  defp scoped(user) do
    case Accounts.server_scope(user) do
      :all -> Ticket
      ids -> where(Ticket, [t], t.server_id in ^ids)
    end
  end

  defp filter(query, filters) do
    Enum.reduce(filters, query, fn
      {:server_id, nil}, query -> query
      {:server_id, id}, query -> where(query, [t], t.server_id == ^id)
      {:status, :active}, query -> where(query, [t], t.status != :closed)
      {:status, nil}, query -> query
      {:status, status}, query -> where(query, [t], t.status == ^status)
      {:query, text}, query -> search(query, text)
      {:category, nil}, query -> query
      {:category, ""}, query -> query
      {:category, category}, query -> where(query, [t], t.category == ^category)
      {:view, view}, query -> view(query, view)
      _other, query -> query
    end)
  end

  # The inbox's built-in views, the way help desks split a queue.
  defp view(query, :unassigned),
    do: where(query, [t], t.status != :closed and is_nil(t.assigned_to_id))

  defp view(query, {:mine, user_id}),
    do: where(query, [t], t.status != :closed and t.assigned_to_id == ^user_id)

  defp view(query, :waiting_admin), do: where(query, [t], t.status == :open)
  defp view(query, :waiting_player), do: where(query, [t], t.status == :answered)
  defp view(query, :active), do: where(query, [t], t.status != :closed)
  defp view(query, :closed), do: where(query, [t], t.status == :closed)
  defp view(query, _all), do: query

  @views [:unassigned, :mine, :waiting_admin, :waiting_player, :active, :closed]

  @doc "The inbox views, in display order."
  @spec views() :: [atom()]
  def views, do: @views

  @doc """
  How many tickets each view holds, for the counts on its tab.
  """
  @spec view_counts(User.t(), term()) :: %{atom() => non_neg_integer()}
  def view_counts(%User{} = user, server_id \\ nil) do
    base = user |> scoped() |> filter(server_id: server_id)

    Map.new(@views, fn name ->
      view = if name == :mine, do: {:mine, user.id}, else: name
      {name, base |> view(view) |> Repo.aggregate(:count)}
    end)
  end

  # A player id matches exactly; anything else matches part of the name.
  defp search(query, text) do
    case String.trim(text || "") do
      "" ->
        query

      text ->
        pattern = "%" <> String.replace(text, ~w(\\ % _), &("\\" <> &1)) <> "%"
        where(query, [t], t.player_id == ^text or ilike(t.player_name, ^pattern))
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp insert_message(ticket, attrs) do
    %Message{}
    |> Message.changeset(Map.put(attrs, :ticket_id, ticket.id))
    |> Repo.insert()
  end

  # System notices are recorded like any other line so the admin sees what the
  # player was told. A blank template means stay quiet.
  defp notify_player(server, ticket, settings, template) do
    case String.trim(template || "") do
      "" ->
        :ok

      text ->
        text = render_notice(text, ticket, settings, server)
        {delivery, error} = deliver(server, ticket, text)

        insert_message(ticket, %{
          author: :system,
          body: text,
          delivery: delivery,
          delivery_error: error
        })

        :ok
    end
  end

  @doc ~S"""
  Fills a notice template. `{player_name}` (or `{player}`) becomes the
  player's name, `{ticket_id}` the ticket's number, `{category}` its
  category, `{categories}` the numbered list the player can answer with,
  `{server_name}` the server and `{command}` the server's first ticket
  command.

      iex> alias HllConditionalActions.Tickets
      iex> settings = %HllConditionalActions.Tickets.Settings{commands: ["!ticket", "!adm"]}
      iex> Tickets.render_notice("Hi {player}, type {command} again", %{player_name: "Sarge"}, settings)
      "Hi Sarge, type !ticket again"
      iex> Tickets.render_notice("Chamado \#{ticket_id} aberto, {player_name}.", %{id: 214, player_name: "Kowalski"}, settings)
      "Chamado #214 aberto, Kowalski."
  """
  @spec render_notice(String.t(), map(), Settings.t(), map() | nil) :: String.t()
  def render_notice(template, ticket, %Settings{} = settings, server \\ nil),
    do: fill(template, notice_vars(ticket, settings, server))

  @doc """
  The placeholders a message template can use, with what they become for a
  ticket.
  """
  @spec notice_vars(map(), Settings.t(), map() | nil) :: %{String.t() => String.t()}
  def notice_vars(ticket, %Settings{} = settings, server) do
    name = Map.get(ticket, :player_name) || ""

    %{
      "player" => name,
      "player_name" => name,
      "command" => List.first(settings.commands || [], ""),
      "ticket_id" => ticket |> Map.get(:id) |> to_string(),
      "category" => Map.get(ticket, :category) || "",
      "categories" => category_menu(settings),
      "server_name" => (server && Map.get(server, :name)) || ""
    }
  end

  @doc """
  Replaces each `{name}` of a template with its value; unknown names stay.

      iex> HllConditionalActions.Tickets.fill("{a} and {b}", %{"a" => "1"})
      "1 and {b}"
  """
  @spec fill(String.t(), %{String.t() => String.t()}) :: String.t()
  def fill(template, vars) do
    Regex.replace(~r/\{([a-z_]+)\}/, template, fn whole, name -> Map.get(vars, name, whole) end)
  end

  defp deliver(server, ticket, text) do
    case Crcon.message_player(server, ticket.player_id, text) do
      {:ok, _result} -> {:sent, nil}
      {:error, error} -> {:failed, Exception.message(error)}
    end
  end

  defp tap_ok({:ok, value} = result, fun) do
    fun.(value)
    result
  end

  defp tap_ok(error, _fun), do: error

  # Replies to in-game commands have no browser to take a language from.
  defp in_default_locale(fun),
    do:
      Gettext.with_locale(
        Application.get_env(:hll_conditional_actions, :default_locale, "en"),
        fun
      )

  @doc """
  The categories used on the servers a user sees, for the inbox filter.
  """
  @spec categories(User.t()) :: [String.t()]
  def categories(user) do
    user
    |> scoped()
    |> where([t], not is_nil(t.category))
    |> distinct(true)
    |> select([t], t.category)
    |> order_by([t], t.category)
    |> Repo.all()
  end

  defp now, do: DateTime.utc_now(:second)
end
