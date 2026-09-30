defmodule HllConditionalActions.Tickets.Announcement do
  @moduledoc """
  Tells a Discord channel that a ticket was opened, through one of the
  registered webhooks (`HllConditionalActions.Discord`).

  Delivery goes through the same queue as rule messages
  (`HllConditionalActions.Workers.DeliverWebhook`), so Discord being slow or
  rate limiting never delays the ticket itself. The message is written in the
  app's default language, since nobody's browser is involved.
  """

  use Gettext, backend: HllConditionalActionsWeb.Gettext

  require Logger

  alias HllConditionalActions.Discord.Message
  alias HllConditionalActions.Servers.Server
  alias HllConditionalActions.Tickets.Settings
  alias HllConditionalActions.Tickets.Ticket
  alias HllConditionalActions.Workers.DeliverWebhook

  # Discord's red for urgent, amber for high, its blurple otherwise.
  @urgent_color 0xED4245
  @high_color 0xF0B232
  @normal_color 0x5865F2

  @doc """
  Queues the announcement of a new ticket, if the server has a webhook set.
  """
  @spec new_ticket(Server.t(), Settings.t(), Ticket.t(), String.t()) :: :ok
  def new_ticket(%Server{}, %Settings{discord_webhook_id: nil}, _ticket, _text), do: :ok

  def new_ticket(%Server{} = server, %Settings{} = settings, %Ticket{} = ticket, text) do
    payload = payload(server, settings, ticket, text)

    case DeliverWebhook.enqueue(settings.discord_webhook_id, payload) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("[tickets] could not queue the Discord announcement: #{inspect(reason)}")
        :ok
    end
  end

  @doc """
  The Discord message for a new ticket.
  """
  @spec payload(Server.t(), Settings.t(), Ticket.t(), String.t()) :: map()
  def payload(server, settings, ticket, text) do
    Gettext.with_locale(locale(), fn ->
      roles =
        if mention?(settings, ticket),
          do: role_ids(settings.discord_mention_role_ids),
          else: []

      title =
        if ticket.source == :rule,
          do: gettext("A rule opened a ticket for %{player}", player: player(ticket)),
          else: gettext("%{player} called an admin", player: player(ticket))

      %{
        "content" => roles |> Enum.map_join(" ", &"<@&#{&1}>") |> blank_to_nil(),
        "allowed_mentions" => %{"parse" => [], "roles" => roles},
        "embeds" => [
          %{
            "title" => title,
            "url" => url(ticket),
            "description" => text,
            "color" => color(ticket.priority),
            "fields" => [
              %{"name" => gettext("Server"), "value" => server.name, "inline" => true},
              %{"name" => gettext("Player ID"), "value" => ticket.player_id, "inline" => true}
            ],
            "timestamp" => DateTime.to_iso8601(ticket.inserted_at)
          }
        ]
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
      |> Message.limit()
    end)
  end

  @doc """
  Role ids from the comma separated setting.

      iex> HllConditionalActions.Tickets.Announcement.role_ids(" 123, 456 ,,")
      ["123", "456"]
  """
  @spec role_ids(String.t() | nil) :: [String.t()]
  def role_ids(nil), do: []
  def role_ids(text), do: text |> String.split(~r/[\s,]+/, trim: true)

  @doc """
  Whether a ticket is important enough to mention the roles: its priority
  at least the server's `mention_min_priority`.

      iex> alias HllConditionalActions.Tickets.{Announcement, Settings, Ticket}
      iex> Announcement.mention?(%Settings{mention_min_priority: "high"}, %Ticket{priority: :normal})
      false
      iex> Announcement.mention?(%Settings{mention_min_priority: "high"}, %Ticket{priority: :urgent})
      true
  """
  @spec mention?(Settings.t(), Ticket.t()) :: boolean()
  def mention?(%Settings{mention_min_priority: min}, %Ticket{priority: priority}),
    do: Ticket.rank(priority) >= Ticket.rank(Ticket.parse_priority(min || "low"))

  defp color(:urgent), do: @urgent_color
  defp color(:high), do: @high_color
  defp color(_priority), do: @normal_color

  defp player(ticket), do: ticket.player_name || ticket.player_id

  defp url(ticket), do: HllConditionalActionsWeb.Endpoint.url() <> "/tickets/#{ticket.id}"

  defp locale, do: Application.get_env(:hll_conditional_actions, :default_locale, "en")

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text
end
