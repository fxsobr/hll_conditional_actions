defmodule HllConditionalActionsWeb.PlayerLive.Parts do
  @moduledoc """
  Pieces the player list and the player 360 page share: the avatar tile in
  the team's colour, the "now" cell, the marks, the last-seen time and the
  number formats.
  """

  use HllConditionalActionsWeb, :html

  alias HllConditionalActions.Players

  # ── Formats ────────────────────────────────────────────────────────────────

  @doc "A whole number with the viewer's thousands separator: 4.812 or 4,812."
  @spec number(integer() | nil) :: String.t()
  def number(nil), do: "0"

  def number(value) when is_integer(value) and value >= 1000 do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.join(if(comma_decimals?(), do: ".", else: ","))
    |> String.reverse()
  end

  def number(value), do: to_string(value)

  @doc "A number with `decimals` places and the viewer's decimal mark: 2,41 or 2.41."
  @spec decimal(number(), non_neg_integer()) :: String.t()
  def decimal(value, decimals \\ 2) do
    text = :erlang.float_to_binary(value / 1, decimals: decimals)
    if comma_decimals?(), do: String.replace(text, ".", ","), else: text
  end

  defp comma_decimals? do
    Gettext.get_locale(HllConditionalActionsWeb.Gettext) in ["pt_BR", "pt", "es", "de", "fr"]
  end

  @doc "Hours played, or a dash."
  @spec hours(integer() | nil) :: String.t()
  def hours(seconds) when is_integer(seconds) and seconds > 0,
    do: gettext("%{count} h", count: number(div(seconds, 3600)))

  def hours(_seconds), do: "–"

  @doc "The colour of a penalty count: quiet at zero, orange from three."
  @spec penalty_tone(integer() | nil) :: String.t() | nil
  def penalty_tone(count) when is_integer(count) and count >= 3, do: "text-axis"
  def penalty_tone(count) when count in [0, nil], do: "text-muted"
  def penalty_tone(_count), do: nil

  @doc ~s(Up to two letters for a name: "Rudi_88" is RU, "Cpt. Nogueira" CN.)
  @spec initials(String.t() | nil) :: String.t()
  def initials(nil), do: "?"

  def initials(name) do
    case name
         |> String.replace(~r/\[[^\]]*\]/u, " ")
         |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
         |> String.split(~r/\s+/, trim: true)
         |> words() do
      [] -> name |> String.slice(0, 2) |> String.upcase()
      [word] -> word |> String.slice(0, 2) |> String.upcase()
      [first, second | _rest] -> String.upcase(String.first(first) <> String.first(second))
    end
  end

  # Words that start with a letter lead: "Rudi_88" is RU, not R8.
  defp words(words) do
    case Enum.filter(words, &String.match?(&1, ~r/^\p{L}/u)) do
      [] -> words
      lettered -> lettered
    end
  end

  @doc "A team's name."
  @spec team_label(String.t() | nil) :: String.t() | nil
  def team_label("allies"), do: gettext("Allies")
  def team_label("axis"), do: gettext("Axis")
  def team_label(_team), do: nil

  @doc "A role's name, as the game calls it."
  @spec role_label(String.t() | nil) :: String.t() | nil
  def role_label("rifleman"), do: gettext("Rifleman")
  def role_label("assault"), do: gettext("Assault")
  def role_label("automaticrifleman"), do: gettext("Automatic rifleman")
  def role_label("medic"), do: gettext("Medic")
  def role_label("support"), do: gettext("Support")
  def role_label("heavymachinegunner"), do: gettext("Machine gunner")
  def role_label("machinegunner"), do: gettext("Machine gunner")
  def role_label("antitank"), do: gettext("Anti-tank")
  def role_label("engineer"), do: gettext("Engineer")
  def role_label("officer"), do: gettext("Squad leader")
  def role_label("spotter"), do: gettext("Spotter")
  def role_label("sniper"), do: gettext("Sniper")
  def role_label("crewman"), do: gettext("Tank crewman")
  def role_label("tankcommander"), do: gettext("Tank commander")
  def role_label("armycommander"), do: gettext("Commander")
  def role_label("artilleryobserver"), do: gettext("Artillery observer")
  def role_label("operator"), do: gettext("Operator")
  def role_label("gunner"), do: gettext("Gunner")
  def role_label("pilot"), do: gettext("Pilot")
  def role_label("grenadier"), do: gettext("Grenadier")
  def role_label("specialist"), do: gettext("Specialist")
  def role_label("logisticsofficer"), do: gettext("Logistics officer")
  def role_label(_role), do: nil

  # ── Marks ──────────────────────────────────────────────────────────────────

  @doc """
  The marks of a list row, most telling first: VIP, watchlist, clan, an
  open ticket, the match's top killer, new players and CRCON's flags.
  """
  @spec marks(map()) :: [{String.t(), String.t()}]
  def marks(row) do
    [
      row.vip? && {gettext("VIP"), "engine"},
      row.watched? && {gettext("Watchlist"), "axis"},
      clan(row) && {gettext("Clan %{tag}", tag: clan(row)), "neutral"},
      row.open_tickets > 0 && {gettext("Open ticket"), "engine"},
      row.live && row.live.top_killer? && {gettext("Top kills"), "neutral"},
      new_mark(row)
    ]
    |> Enum.filter(& &1)
    |> Kernel.++(flag_marks(row.flags))
  end

  defp clan(%{live: %{clan_tag: tag}}) when is_binary(tag), do: strip_brackets(tag)
  defp clan(%{clan_tag: tag}) when is_binary(tag), do: strip_brackets(tag)

  defp clan(%{name: name}) when is_binary(name) do
    case Regex.run(~r/\[([^\]]{2,6})\]/u, name) do
      [_all, tag] -> tag
      nil -> nil
    end
  end

  defp clan(_row), do: nil

  defp strip_brackets(tag) do
    case tag |> String.replace(~r/[\[\]]/u, "") |> String.trim() do
      "" -> nil
      tag -> tag
    end
  end

  defp new_mark(%{first_seen: %NaiveDateTime{} = first} = row) do
    week_ago = NaiveDateTime.add(NaiveDateTime.utc_now(), -7 * 86_400, :second)

    cond do
      NaiveDateTime.compare(first, week_ago) == :lt -> nil
      # CRCON counted too many sessions for somebody new to this install.
      is_integer(row.sessions) and row.sessions > 10 -> nil
      is_integer(row.sessions) and row.sessions > 0 -> {new_session(row.sessions), "primary"}
      true -> {gettext("New"), "primary"}
    end
  end

  defp new_mark(_row), do: nil

  defp new_session(sessions), do: gettext("New · session %{count}", count: sessions)

  defp flag_marks(flags) when is_list(flags) do
    Enum.flat_map(flags, fn
      %{"comment" => comment} when is_binary(comment) and byte_size(comment) <= 16 ->
        [{comment, "neutral"}]

      %{"flag" => flag} when is_binary(flag) ->
        [{flag, "neutral"}]

      _other ->
        []
    end)
  end

  defp flag_marks(_flags), do: []

  attr :mark, :any, required: true

  @doc "A mark: a small tinted pill."
  def mark(assigns) do
    ~H"""
    <span class={["players-mark", "players-mark--#{elem(@mark, 1)}"]}>{elem(@mark, 0)}</span>
    """
  end

  # ── Avatar, now, seen ──────────────────────────────────────────────────────

  attr :name, :string, default: nil
  attr :team, :string, default: nil
  attr :size, :string, default: "sm", values: ~w(sm md lg)

  @doc "The player's initials on a tile of their team's colour."
  def avatar_tile(assigns) do
    ~H"""
    <span class={["players-avatar", "players-avatar--#{@size}", avatar_tone(@team)]}>
      {initials(@name)}
    </span>
    """
  end

  defp avatar_tone("axis"), do: "bg-axis/16 text-axis"
  defp avatar_tone("allies"), do: "bg-allies/14 text-allies"
  defp avatar_tone(_team), do: "bg-secondary text-subtle"

  attr :live, :any, default: nil

  @doc "Where the player is right now: team and server, or offline."
  def now_cell(%{live: nil} = assigns) do
    ~H"""
    <span class="flex min-w-0 items-center gap-2 text-[0.8125rem]">
      <span class="players-dot players-dot--off" aria-hidden="true"></span>
      <span class="text-muted">{gettext("offline")}</span>
    </span>
    """
  end

  def now_cell(%{live: %{stream?: false}} = assigns) do
    ~H"""
    <span class="flex min-w-0 items-center gap-2 text-[0.8125rem]">
      <span class="players-dot bg-warning" aria-hidden="true"></span>
      <span class="shrink-0 text-subtle">{Players.short_name(@live.server_name)}</span>
      <span class="truncate text-muted">· {gettext("no stream")}</span>
    </span>
    """
  end

  def now_cell(assigns) do
    ~H"""
    <span class="flex min-w-0 items-center gap-2 text-[0.8125rem]">
      <span class="players-dot bg-primary" aria-hidden="true"></span>
      <%= if team_label(@live.team) do %>
        <span class={["shrink-0", team_text(@live.team)]}>{team_label(@live.team)}</span>
        <span class="truncate text-muted">· {Players.short_name(@live.server_name)}</span>
      <% else %>
        <span class="truncate text-subtle">{Players.short_name(@live.server_name)}</span>
      <% end %>
    </span>
    """
  end

  attr :id, :string, required: true
  attr :at, :any, required: true
  attr :class, :any, default: nil
  attr :variant, :string, default: "list", values: ~w(list timeline short)

  @doc """
  When the player was last seen, in the viewer's time: "21:43" within a few
  hours, "hoje 19:40", "ontem", "27 set".
  """
  def seen(%{at: nil} = assigns), do: ~H"<span class={@class}>–</span>"

  def seen(assigns) do
    assigns = assign(assigns, :iso, iso(assigns.at))

    ~H"""
    <time
      id={@id}
      datetime={@iso}
      class={@class}
      phx-hook=".SeenAt"
      data-variant={@variant}
      data-today={
        if @variant == "timeline",
          do: gettext("Today %{time}", time: "%{time}"),
          else: gettext("today %{time}", time: "%{time}")
      }
      data-yesterday={if @variant != "list", do: gettext("Yesterday"), else: gettext("yesterday")}
    >
      {String.slice(@iso, 0, 10)}
    </time>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".SeenAt">
      export default {
        mounted() { this.render() },
        updated() { this.render() },
        render() {
          const at = new Date(this.el.getAttribute("datetime"))
          if (isNaN(at)) return
          const lang = document.documentElement.lang || undefined
          const now = new Date()
          const time = at.toLocaleTimeString(lang, {hour: "2-digit", minute: "2-digit"})
          const day = (d) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime()
          const days = Math.round((day(now) - day(at)) / 86400000)
          let text
          const variant = this.el.dataset.variant
          if (days === 0 && (variant === "short" || (variant === "list" && now - at < 3 * 3600000))) text = time
          else if (days === 0) text = this.el.dataset.today.replace("%{time}", time)
          else if (days === 1) text = this.el.dataset.yesterday
          else {
            const month = at.toLocaleDateString(lang, {month: "short"}).replace(".", "")
            text = at.getDate() + " " + month + (at.getFullYear() === now.getFullYear() ? "" : " " + at.getFullYear())
          }
          this.el.textContent = text
          this.el.title = at.toLocaleString(lang)
        }
      }
    </script>
    """
  end

  @doc "A month's short name: set, out."
  @spec month(1..12) :: String.t()
  def month(1), do: gettext("Jan")
  def month(2), do: gettext("Feb")
  def month(3), do: gettext("Mar")
  def month(4), do: gettext("Apr")
  def month(5), do: gettext("May")
  def month(6), do: gettext("Jun")
  def month(7), do: gettext("Jul")
  def month(8), do: gettext("Aug")
  def month(9), do: gettext("Sep")
  def month(10), do: gettext("Oct")
  def month(11), do: gettext("Nov")
  def month(12), do: gettext("Dec")

  defp iso(%NaiveDateTime{} = at),
    do: at |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601() |> Kernel.<>("Z")

  defp iso(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  # ── CSV ────────────────────────────────────────────────────────────────────

  @doc "The list's rows as CSV, one player per line."
  @spec csv([map()]) :: String.t()
  def csv(rows) do
    header = [
      "player_id",
      "name",
      "online_on",
      "team",
      "level",
      "playtime_hours",
      "sessions",
      "penalties",
      "rule_hits",
      "tickets",
      "vip",
      "watchlist",
      "first_seen",
      "last_seen"
    ]

    lines =
      Enum.map(rows, fn row ->
        [
          row.id,
          row.name,
          row.live && row.live.server_name,
          row.live && row.live.team,
          row.level,
          if(is_integer(row.playtime), do: div(row.playtime, 3600)),
          row.sessions,
          row.penalties,
          row.hits,
          row.tickets,
          row.vip?,
          row.watched?,
          row.first_seen && iso(row.first_seen),
          if(row.live, do: iso(DateTime.utc_now()), else: row.seen_at && iso(row.seen_at))
        ]
      end)

    [header | lines]
    |> Enum.map_join("\r\n", fn cells -> Enum.map_join(cells, ",", &cell/1) end)
  end

  defp cell(nil), do: ""

  defp cell(value) when is_binary(value) do
    # A leading = + - @ would make a spreadsheet run the cell as a formula.
    value = if String.match?(value, ~r/^[=+\-@]/), do: "'" <> value, else: value

    if String.contains?(value, [",", "\"", "\n", "\r"]),
      do: "\"" <> String.replace(value, "\"", "\"\"") <> "\"",
      else: value
  end

  defp cell(value), do: to_string(value)
end
