defmodule HllConditionalActionsWeb.CommunityComponents do
  @moduledoc """
  The pieces the community pages (seasons, achievements, matches) share and
  the rest of the app does not: the header pill buttons, the small segmented
  controls inside panels, switches and steppers of the forms, the week
  movement of a ranking, team avatars, the CSV download and the date words
  of the lists.
  """

  use HllConditionalActionsWeb, :html

  # ── Buttons ────────────────────────────────────────────────────────────────

  @doc """
  A 48px pill button of the page header. `primary` is the page's main
  action: the signal in the dark, near-black on light paper.
  """
  attr :primary, :boolean, default: false
  attr :icon, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(navigate patch href download type disabled form name value)
  slot :inner_block, required: true

  def pill_button(assigns) do
    ~H"""
    <.link
      :if={@rest[:navigate] || @rest[:patch] || @rest[:href]}
      class={[pill_class(@primary), @class]}
      {@rest}
    >
      <.icon :if={@icon} name={@icon} class="size-[1.125rem] shrink-0" />
      <span>{render_slot(@inner_block)}</span>
    </.link>
    <button
      :if={!(@rest[:navigate] || @rest[:patch] || @rest[:href])}
      class={[pill_class(@primary), @class]}
      {@rest}
    >
      <.icon :if={@icon} name={@icon} class="size-[1.125rem] shrink-0" />
      <span>{render_slot(@inner_block)}</span>
    </button>
    """
  end

  defp pill_class(true), do: "com-pill com-pill--primary"
  defp pill_class(false), do: "com-pill"

  @doc "A round 44px back button, for the pages whose header the shell draws without one."
  attr :navigate, :string, required: true
  attr :label, :string, required: true

  def back_button(assigns) do
    ~H"""
    <.link navigate={@navigate} aria-label={@label} class="com-back">
      <.icon name="hero-chevron-left" class="size-5" />
    </.link>
    """
  end

  # ── Choices ────────────────────────────────────────────────────────────────

  @doc """
  Small pill tabs inside a panel: links (`patch`/`navigate`) or buttons
  (`click` with `value`). `raised` puts them on the raised tone, for use
  inside a panel.
  """
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :raised, :boolean, default: true
  attr :class, :any, default: nil

  slot :item, required: true do
    attr :patch, :string
    attr :navigate, :string
    attr :click, :string
    attr :value, :any
    attr :active, :boolean
    attr :class, :any
    attr :dot, :string
  end

  def seg(assigns) do
    ~H"""
    <div
      id={@id}
      role="tablist"
      aria-label={@label}
      class={["com-seg", @raised && "com-seg--raised", @class]}
    >
      <%= for item <- @item do %>
        <.link
          :if={item[:patch] || item[:navigate]}
          patch={item[:patch]}
          navigate={item[:navigate]}
          role="tab"
          aria-selected={to_string(item[:active] == true)}
          class={["com-seg-item", item[:class]]}
        >
          {render_slot(item)}
          <span :if={item[:dot]} class={["size-1.5 rounded-full", item[:dot]]}></span>
        </.link>
        <button
          :if={!(item[:patch] || item[:navigate])}
          type="button"
          role="tab"
          phx-click={item[:click]}
          value={item[:value]}
          phx-value-value={item[:value]}
          aria-selected={to_string(item[:active] == true)}
          class={["com-seg-item", item[:class]]}
        >
          {render_slot(item)}
          <span :if={item[:dot]} class={["size-1.5 rounded-full", item[:dot]]}></span>
        </button>
      <% end %>
    </div>
    """
  end

  @doc """
  A radio group drawn as a segmented control, for forms: the chosen option
  is filled. `options` are `{label, value}` pairs.
  """
  attr :name, :string, required: true
  attr :value, :any, default: nil
  attr :options, :list, required: true
  attr :label, :string, required: true
  attr :id, :string, required: true
  attr :class, :any, default: nil
  attr :round, :boolean, default: false, doc: "pill shaped instead of a field"

  slot :option_prefix, doc: "rendered before each label, receives the value"

  def radio_seg(assigns) do
    ~H"""
    <div
      id={@id}
      role="radiogroup"
      aria-label={@label}
      class={["com-radio-seg", @round && "com-radio-seg--round", @class]}
      style={"grid-template-columns: repeat(#{length(@options)}, minmax(0, 1fr))"}
    >
      <label :for={{label, value} <- @options} class="com-radio-seg-item">
        <input
          type="radio"
          name={@name}
          value={value}
          checked={to_string(@value) == to_string(value)}
          class="peer sr-only"
        />
        <span>
          {render_slot(@option_prefix, value)}
          {label}
        </span>
      </label>
    </div>
    """
  end

  @doc "An on/off switch backed by a checkbox (the hidden input sends \"false\")."
  attr :name, :string, required: true
  attr :checked, :boolean, default: false
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :tone, :string, default: "primary", values: ~w(primary engine)
  attr :small, :boolean, default: false

  def toggle_switch(assigns) do
    ~H"""
    <span class={["com-switch", @tone == "engine" && "com-switch--engine", @small && "com-switch--sm"]}>
      <input type="hidden" name={@name} value="false" />
      <input
        type="checkbox"
        role="switch"
        id={@id}
        name={@name}
        value="true"
        checked={@checked}
        aria-label={@label}
      />
      <span class="com-switch-knob" aria-hidden="true"></span>
    </span>
    """
  end

  @doc "A number with − and + beside it, for small counts in forms."
  attr :name, :string, required: true
  attr :value, :any, required: true
  attr :id, :string, required: true
  attr :min, :integer, default: 0
  attr :max, :integer, default: 999
  attr :less, :string, required: true, doc: "label of the − button"
  attr :more, :string, required: true, doc: "label of the + button"
  attr :field, :string, required: true, doc: "the param the buttons step"

  def count_stepper(assigns) do
    ~H"""
    <div class="com-stepper" id={@id}>
      <button
        type="button"
        aria-label={@less}
        phx-click="step"
        phx-value-field={@field}
        phx-value-by="-1"
      >
        −
      </button>
      <input
        type="number"
        name={@name}
        value={@value}
        min={@min}
        max={@max}
        class="font-mono"
        aria-label={@field}
      />
      <button
        type="button"
        aria-label={@more}
        phx-click="step"
        phx-value-field={@field}
        phx-value-by="1"
      >
        +
      </button>
    </div>
    """
  end

  # ── Small marks ────────────────────────────────────────────────────────────

  @doc "A form section's title: mono, uppercase, with a hairline above."
  attr :first, :boolean, default: false
  slot :inner_block, required: true

  def section_label(assigns) do
    ~H"""
    <span class={["com-section-label", !@first && "com-section-label--rule"]}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  @doc "\"● ao vivo\": the signal dot and word the previews and feeds carry."
  attr :id, :string, default: nil

  def live_mark(assigns) do
    ~H"""
    <span id={@id} class="flex shrink-0 items-center gap-1.5 text-xs text-primary">
      <span class="size-[7px] rounded-full bg-primary" aria-hidden="true"></span>
      {gettext("live")}
    </span>
    """
  end

  @doc """
  How far a player moved in a ranking: "↑ 2", "↓ 1", "=", "novo", or "–"
  when there is nothing to compare with.
  """
  attr :moved, :any, required: true

  def delta(assigns) do
    ~H"""
    <%= case @moved do %>
      <% :new -> %>
        <span class="text-xs text-accent">{gettext("new")}</span>
      <% 0 -> %>
        <span class="text-xs text-muted">=</span>
      <% n when is_integer(n) and n > 0 -> %>
        <span class="text-xs text-primary">↑ {n}</span>
      <% n when is_integer(n) -> %>
        <span class="text-xs text-error">↓ {abs(n)}</span>
      <% _unknown -> %>
        <span class="text-xs text-muted">–</span>
    <% end %>
    """
  end

  @doc "A player's initials in their team's tint."
  attr :name, :string, required: true
  attr :team, :any, default: nil
  attr :class, :any, default: "size-7 rounded-[0.5625rem] text-[0.6875rem]"
  attr :ring, :boolean, default: false

  def team_avatar(assigns) do
    ~H"""
    <span class={[
      "flex shrink-0 items-center justify-center font-bold",
      team_tint(@team),
      @ring && "ring-2 ring-base-100",
      @class
    ]}>
      {initials(@name)}
    </span>
    """
  end

  @doc "The tinted background and text of a team."
  @spec team_tint(term()) :: String.t()
  def team_tint(team) when team in ["allies", :allies], do: "bg-allies/15 text-allies"
  def team_tint(team) when team in ["axis", :axis], do: "bg-axis/16 text-axis"
  def team_tint(_team), do: "bg-base-300 text-subtle"

  @doc "The dot of a team."
  @spec team_dot(term()) :: String.t()
  def team_dot(team) when team in ["allies", :allies], do: "bg-allies"
  def team_dot(team) when team in ["axis", :axis], do: "bg-axis"
  def team_dot(_team), do: "bg-base-300"

  @doc """
  Two letters of a name, skipping clan tags: "Kowalski [7DV]" is "KO".

      iex> HllConditionalActionsWeb.CommunityComponents.initials("Cpt. Nogueira")
      "CN"
      iex> HllConditionalActionsWeb.CommunityComponents.initials("Kowalski [7DV]")
      "KO"
  """
  @spec initials(String.t() | nil) :: String.t()
  def initials(name) when is_binary(name) do
    words =
      name
      |> String.replace(~r/[\[\(].*?[\]\)]/u, "")
      |> String.split(~r/[\s_.\-]+/u, trim: true)
      |> Enum.filter(&String.match?(&1, ~r/^\p{L}/u))

    case words do
      [one] ->
        one |> String.slice(0, 2) |> String.upcase()

      [first, second | _rest] ->
        String.upcase(String.first(first) <> String.first(second))

      [] ->
        name |> String.replace(~r/[^\p{L}\p{N}]/u, "") |> String.slice(0, 2) |> String.upcase()
    end
  end

  def initials(_name), do: "?"

  @doc "The label of a team."
  @spec team_label(term()) :: String.t() | nil
  def team_label(team) when team in ["allies", :allies], do: gettext("Allies")
  def team_label(team) when team in ["axis", :axis], do: gettext("Axis")
  def team_label(_team), do: nil

  # ── CSV ────────────────────────────────────────────────────────────────────

  @doc """
  The element that turns a `"download_csv"` event (`%{filename, content}`)
  into a file download. One per page.
  """
  attr :id, :string, required: true

  def csv_download(assigns) do
    ~H"""
    <div id={@id} phx-hook=".CsvDownload" class="hidden"></div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".CsvDownload">
      export default {
        mounted() {
          this.handleEvent("download_csv", ({filename, content}) => {
            const blob = new Blob(["﻿" + content], {type: "text/csv;charset=utf-8"})
            const url = URL.createObjectURL(blob)
            const link = document.createElement("a")
            link.href = url
            link.download = filename
            document.body.appendChild(link)
            link.click()
            link.remove()
            setTimeout(() => URL.revokeObjectURL(url), 1000)
          })
        }
      }
    </script>
    """
  end

  @doc """
  Rows as CSV text: a header row and one line per row, quoted where needed.

      iex> HllConditionalActionsWeb.CommunityComponents.to_csv(["a", "b"], [[1, "x,y"]])
      "a,b\\r\\n1,\\"x,y\\"\\r\\n"
  """
  @spec to_csv([String.t()], [[term()]]) :: String.t()
  def to_csv(header, rows) do
    [header | rows]
    |> Enum.map_join("", fn row -> Enum.map_join(row, ",", &csv_cell/1) <> "\r\n" end)
  end

  defp csv_cell(nil), do: ""

  defp csv_cell(value) do
    text = to_string(value)

    if String.contains?(text, [",", "\"", "\n", "\r"]),
      do: "\"" <> String.replace(text, "\"", "\"\"") <> "\"",
      else: text
  end

  # ── Numbers, dates, durations ──────────────────────────────────────────────

  @doc """
  A whole number with the viewer's thousands separator: "9.340" in
  Portuguese, "9,340" in English.
  """
  @spec number(number() | nil) :: String.t()
  def number(nil), do: "–"
  def number(value) when is_float(value), do: decimal(value, 2)

  def number(value) when is_integer(value) do
    {sep, _decimal} = separators()

    value
    |> abs()
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(sep, &Enum.join/1)
    |> String.reverse()
    |> then(&if(value < 0, do: "-" <> &1, else: &1))
  end

  @doc "A number with `places` decimals and the viewer's decimal mark: \"4,22\"."
  @spec decimal(number(), non_neg_integer()) :: String.t()
  def decimal(value, places) do
    value
    |> Kernel.*(1.0)
    |> :erlang.float_to_binary(decimals: places)
    |> String.replace(".", elem(separators(), 1))
  end

  defp separators, do: HllConditionalActionsWeb.NumberFormat.separators()

  @doc ~s(A length of time: "48 min", "1h32".)
  @spec duration(integer() | nil) :: String.t()
  def duration(nil), do: "—"
  def duration(seconds) when seconds < 3600, do: "#{div(seconds, 60)} min"

  def duration(seconds) do
    minutes = seconds |> rem(3600) |> div(60) |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{div(seconds, 3600)}h#{minutes}"
  end

  @doc "A UTC time in a server's time zone."
  @spec local(DateTime.t() | nil, map() | nil) :: DateTime.t() | nil
  def local(nil, _server), do: nil

  def local(at, server) do
    zone = (server && Map.get(server, :timezone)) || "Etc/UTC"

    case DateTime.shift_zone(at, zone) do
      {:ok, shifted} -> shifted
      _error -> at
    end
  end

  @doc "\"21:02\"."
  @spec clock(DateTime.t() | nil) :: String.t()
  def clock(nil), do: "—"
  def clock(at), do: Calendar.strftime(at, "%H:%M")

  @doc "\"terça, 29 de setembro\" in the viewer's language."
  @spec long_date(Date.t()) :: String.t()
  def long_date(date) do
    gettext("%{weekday}, %{day} %{month}",
      weekday: weekday(Date.day_of_week(date)),
      day: date.day,
      month: month(date.month)
    )
  end

  @doc "\"29 set\": a day and a short month."
  @spec short_date(Date.t()) :: String.t()
  def short_date(date), do: "#{date.day} #{String.slice(month(date.month), 0, 3)}"

  defp weekday(1), do: gettext("monday")
  defp weekday(2), do: gettext("tuesday")
  defp weekday(3), do: gettext("wednesday")
  defp weekday(4), do: gettext("thursday")
  defp weekday(5), do: gettext("friday")
  defp weekday(6), do: gettext("saturday")
  defp weekday(7), do: gettext("sunday")

  defp month(1), do: gettext("january")
  defp month(2), do: gettext("february")
  defp month(3), do: gettext("march")
  defp month(4), do: gettext("april")
  defp month(5), do: gettext("may")
  defp month(6), do: gettext("june")
  defp month(7), do: gettext("july")
  defp month(8), do: gettext("august")
  defp month(9), do: gettext("september")
  defp month(10), do: gettext("october")
  defp month(11), do: gettext("november")
  defp month(12), do: gettext("december")
end
