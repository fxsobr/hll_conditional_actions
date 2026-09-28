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
  alias HllConditionalActions.Tickets.Message
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
  def match_command(nil, _commands), do: :nomatch

  def match_command(message, commands) do
    message = String.trim(message)

    [first | rest] = String.split(message, ~r/\s+/, parts: 2)

    if String.downcase(first) in commands,
      do: {:ok, rest |> List.first("") |> String.trim()},
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

  defp route_chat(server, settings, event, log_key, opts) do
    open = open_ticket(server.id, event.player_id)

    case {match_command(event.chat_message, settings.commands), open} do
      {{:ok, text}, open} when text != "" ->
        handle_command(server, settings, event, {text, log_key, opts}, open)

      {{:ok, ""}, nil} ->
        open_if_allowed(server, settings, event, "", log_key, opts)

      {{:ok, ""}, %Ticket{} = ticket} ->
        {:added, ticket}

      {:nomatch, %Ticket{} = ticket} ->
        {:added, add_player_line(ticket, event, String.trim(event.chat_message || ""), log_key)}

      {:nomatch, nil} ->
        :ignored
    end
  end

  defp handle_command(server, settings, event, {text, log_key, opts}, open) do
    case player_command(text, settings) do
      :status -> {:status, tell_status(server, settings, event, open)}
      :close -> {:closed, close_by_player(open)}
      nil -> command_text(server, settings, event, text, log_key, opts, open)
    end
  end

  defp command_text(server, settings, event, text, log_key, opts, nil),
    do: open_if_allowed(server, settings, event, text, log_key, opts)

  defp command_text(_server, _settings, event, text, log_key, _opts, ticket),
    do: {:added, add_player_line(ticket, event, text, log_key)}

  defp open_if_allowed(server, settings, event, text, log_key, opts) do
    cond do
      cooling_down?(server.id, event.player_id, settings) -> :cooldown
      over_hourly_limit?(server.id, event.player_id, settings) -> :rate_limited
      true -> open_new(server, settings, event, text, log_key, opts)
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
  Splits a category off the ticket text: the first word, when the server
  lists it as a category.

      iex> alias HllConditionalActions.Tickets
      iex> settings = %HllConditionalActions.Tickets.Settings{category_priorities: %{"tk" => "high", "cheat" => "urgent"}}
      iex> Tickets.split_category("Cheat aimbot on the hill", settings)
      {"cheat", "aimbot on the hill"}
      iex> Tickets.split_category("help me", settings)
      {nil, "help me"}
  """
  @spec split_category(String.t(), Settings.t()) :: {String.t() | nil, String.t()}
  def split_category(text, %Settings{} = settings) do
    categories = Settings.categories(settings)

    case String.split(text, ~r/\s+/, parts: 2) do
      [first | rest] ->
        if String.downcase(first) in categories,
          do: {String.downcase(first), rest |> List.first("") |> String.trim()},
          else: {nil, text}

      [] ->
        {nil, text}
    end
  end

  @doc """
  Whether a moment falls inside the server's office hours. Always true when
  the server has none. A window that ends before it starts runs past
  midnight (20:00 to 02:00).

      iex> alias HllConditionalActions.Tickets
      iex> settings = %HllConditionalActions.Tickets.Settings{hours_enabled: true, hours_start: ~T[20:00:00], hours_end: ~T[02:00:00], hours_days: [1, 2, 3, 4, 5, 6, 7]}
      iex> Tickets.in_hours?(settings, "Etc/UTC", ~U[2026-09-26 23:00:00Z])
      true
      iex> Tickets.in_hours?(settings, "Etc/UTC", ~U[2026-09-26 12:00:00Z])
      false
  """
  @spec in_hours?(Settings.t(), String.t() | nil, DateTime.t()) :: boolean()
  def in_hours?(%Settings{hours_enabled: true} = settings, timezone, %DateTime{} = at)
      when not is_nil(settings.hours_start) and not is_nil(settings.hours_end) do
    local =
      case DateTime.shift_zone(at, timezone || "Etc/UTC") do
        {:ok, local} -> local
        {:error, _reason} -> at
      end

    case window_day(local, settings.hours_start, settings.hours_end) do
      nil -> false
      day -> day in (settings.hours_days || [])
    end
  end

  def in_hours?(_settings, _timezone, _at), do: true

  # The weekday whose hours a moment falls in, or nil outside them. Past
  # midnight, the hours belong to the day they started on.
  defp window_day(local, start, finish) do
    time = DateTime.to_time(local)
    after_start? = Time.compare(time, start) != :lt
    before_end? = Time.compare(time, finish) == :lt

    cond do
      Time.compare(start, finish) != :gt ->
        if after_start? and before_end?, do: Date.day_of_week(local)

      after_start? ->
        Date.day_of_week(local)

      before_end? ->
        local |> DateTime.to_date() |> Date.add(-1) |> Date.day_of_week()

      true ->
        nil
    end
  end

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

  defp open_ticket(server_id, player_id) do
    Repo.one(
      from t in Ticket,
        where: t.server_id == ^server_id and t.player_id == ^player_id and t.status != :closed
    )
  end

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

    # A bare command still says something: keep what the player typed.
    body = if text == "", do: String.trim(event.chat_message), else: text

    attrs = %{
      server_id: server.id,
      player_id: event.player_id,
      player_name: event.player_name,
      source: :chat,
      category: category,
      priority: priority_for(category, settings),
      context: Context.capture(Keyword.get(opts, :recent, []), event)
    }

    case insert_ticket(attrs, %{author: :player, body: body, log_key: log_key}) do
      {:ok, ticket} ->
        notify_player(server, ticket, settings, greeting(server, settings))
        announce(server, settings, ticket, body)
        Phoenix.PubSub.broadcast(PubSub, @topic, {:ticket_opened, ticket})
        {:opened, broadcast(ticket)}

      # Another line from the same player won the race; join that ticket.
      {:error, _changeset} ->
        case open_ticket(server.id, event.player_id) do
          nil -> :ignored
          ticket -> {:added, add_player_line(ticket, event, text, log_key)}
        end
    end
  end

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

  def priority_for(category, settings),
    do:
      Ticket.parse_priority(
        Map.get(settings.category_priorities || %{}, category, settings.default_priority)
      )

  # Outside office hours the player is told nobody is around.
  defp greeting(server, settings) do
    if in_hours?(settings, server.timezone, DateTime.utc_now()),
      do: settings.received_message,
      else: settings.offline_message || settings.received_message
  end

  defp insert_ticket(attrs, first_message) do
    Repo.transaction(fn ->
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

  defp add_player_line(ticket, _event, "", _log_key), do: ticket

  defp add_player_line(ticket, event, text, log_key) do
    case insert_message(ticket, %{author: :player, body: text, log_key: log_key}) do
      {:ok, _message} ->
        ticket
        |> Ticket.update_changeset(%{
          status: :open,
          player_name: event.player_name || ticket.player_name,
          last_activity_at: now()
        })
        |> Repo.update!()
        |> broadcast()

      # The same line twice at once: the first one already counted.
      {:error, _changeset} ->
        ticket
    end
  end

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
          announce(server, get_settings(server.id), ticket, note)
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

  defp announce(server, settings, ticket, text),
    do: Announcement.new_ticket(server, settings, ticket, text)

  # ── Admin actions ──────────────────────────────────────────────────────────

  @doc """
  Sends an admin's answer to the player and records it.

  The line is stored even if CRCON refuses it - the player may have left -
  with the delivery outcome, so the admin sees it did not arrive.
  """
  @spec reply(Ticket.t(), User.t(), String.t()) ::
          {:ok, Message.t()} | {:error, :closed | :empty | Ecto.Changeset.t()}
  def reply(%Ticket{status: :closed}, _user, _body), do: {:error, :closed}

  def reply(%Ticket{} = ticket, %User{} = user, body) do
    case String.trim(body || "") do
      "" ->
        {:error, :empty}

      text ->
        server = Repo.get!(Server, ticket.server_id)
        settings = get_settings(ticket.server_id)
        {delivery, error} = deliver(server, ticket, in_game_reply(settings, user, text))

        with {:ok, message} <-
               insert_message(ticket, %{
                 author: :admin,
                 user_id: user.id,
                 body: text,
                 delivery: delivery,
                 delivery_error: error
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
  @spec in_game_reply(Settings.t(), map(), String.t()) :: String.t()
  def in_game_reply(%Settings{reply_prefix: prefix}, user, text) do
    case String.trim(prefix || "") do
      "" -> text
      prefix -> String.replace(prefix, "{admin}", admin_name(user)) <> " " <> text
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
  @spec reopen(Ticket.t()) :: {:ok, Ticket.t()} | {:error, Ecto.Changeset.t()}
  def reopen(%Ticket{} = ticket) do
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
  def player_actions, do: [:punish, :kick, :watch, :temp_ban]

  @doc """
  Runs a CRCON action on the ticket's player - or on another player the
  ticket is about, when `target_id` is given (the one being reported) - and
  records it in the conversation, so the next admin sees what was done.
  """
  @spec act(Ticket.t(), User.t(), atom(), String.t(), String.t() | nil, keyword()) ::
          {:ok, Message.t()}
          | {:error, :empty_reason | :unknown_action | :bad_duration | String.t()}
  def act(%Ticket{} = ticket, %User{} = user, action, reason, target_id \\ nil, opts \\ []) do
    hours = Keyword.get(opts, :duration_hours, 2)
    reason = String.trim(reason || "")
    target = if blank?(target_id), do: ticket.player_id, else: String.trim(target_id)

    with :ok <- check_action(action, reason, hours) do
      server = Repo.get!(Server, ticket.server_id)

      case run_player_action(server, action, target, "#{reason} - #{admin_name(user)}", hours) do
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

  defp check_action(action, reason, hours) do
    cond do
      action not in player_actions() -> {:error, :unknown_action}
      reason == "" -> {:error, :empty_reason}
      action == :temp_ban and not valid_hours?(hours) -> {:error, :bad_duration}
      true -> :ok
    end
  end

  defp valid_hours?(hours), do: is_integer(hours) and hours in 1..8760

  defp run_player_action(server, :punish, player_id, reason, _hours),
    do: Crcon.punish(server, player_id, reason)

  defp run_player_action(server, :kick, player_id, reason, _hours),
    do: Crcon.kick(server, player_id, reason)

  defp run_player_action(server, :watch, player_id, reason, _hours),
    do: Crcon.watch_player(server, player_id, reason)

  defp run_player_action(server, :temp_ban, player_id, reason, hours),
    do: Crcon.temp_ban(server, player_id, hours, reason)

  # Stored as data, read by admins of any language: kept as CRCON's own verbs.
  defp action_note(:punish, _hours), do: "PUNISH"
  defp action_note(:kick, _hours), do: "KICK"
  defp action_note(:watch, _hours), do: "WATCHLIST"
  defp action_note(:temp_ban, hours), do: "TEMPBAN #{hours}h"

  defp target_label(%Ticket{player_id: id} = ticket, id), do: ticket.player_name || id
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
        text = render_notice(text, ticket, settings)
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

  @doc """
  Fills a notice template: `{player}` becomes the player's name and
  `{command}` the server's first ticket command.

      iex> alias HllConditionalActions.Tickets
      iex> settings = %HllConditionalActions.Tickets.Settings{commands: ["!ticket", "!adm"]}
      iex> Tickets.render_notice("Hi {player}, type {command} again", %{player_name: "Sarge"}, settings)
      "Hi Sarge, type !ticket again"
  """
  @spec render_notice(String.t(), map(), Settings.t()) :: String.t()
  def render_notice(template, ticket, %Settings{commands: commands}) do
    template
    |> String.replace("{player}", ticket.player_name || "")
    |> String.replace("{command}", List.first(commands || [], ""))
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
