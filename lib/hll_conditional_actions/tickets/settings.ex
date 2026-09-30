defmodule HllConditionalActions.Tickets.Settings do
  @moduledoc """
  How tickets work on one server: whether they are on, which chat commands
  open one, and what the player is told along the way.

  A server without a row has tickets off. Messages left blank are simply not
  sent, so an admin can keep the game chat quiet.
  """

  use Ecto.Schema
  use Gettext, backend: HllConditionalActionsWeb.Gettext

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  # HLL drops private messages much longer than this.
  @max_message 300
  @max_commands 10

  schema "ticket_settings" do
    belongs_to :server, HllConditionalActions.Servers.Server

    field :enabled, :boolean, default: false
    field :commands, {:array, :string}, default: []
    field :cooldown_seconds, :integer, default: 60
    field :auto_close_hours, :integer, default: 12
    field :received_message, :string
    field :reply_prefix, :string
    field :closed_message, :string
    field :attention_minutes, :integer, default: 5
    field :max_per_hour, :integer, default: 0
    field :quick_replies, {:array, :string}, default: []
    field :discord_mention_role_ids, :string
    # Category name => priority ("low", "normal", "high", "urgent").
    field :category_priorities, :map, default: %{}
    field :default_priority, :string, default: "normal"
    field :status_word, :string
    field :close_word, :string
    field :hours_enabled, :boolean, default: false
    field :hours_start, :time
    field :hours_end, :time
    field :hours_days, {:array, :integer}, default: [1, 2, 3, 4, 5, 6, 7]
    field :offline_message, :string
    # Weekday ("1" Monday .. "7" Sunday) => [["18:00", "24:00"], ...]. Empty
    # means the single window of `hours_start`/`hours_end` on `hours_days`.
    field :hours_ranges, :map, default: %{}
    # Category name => colour key (see `colors/0`), and the order they show in.
    field :category_colors, :map, default: %{}
    field :category_order, {:array, :string}, default: []
    # Quick replies: %{"title" => ..., "body" => ..., "closes" => boolean}.
    field :replies, {:array, :map}, default: []
    field :warn_before_close, :boolean, default: false
    # The lowest priority that mentions the Discord roles.
    field :mention_min_priority, :string, default: "low"
    field :accept_offline, :boolean, default: true
    field :offline_alert_urgent, :boolean, default: true
    field :ignore_case, :boolean, default: true
    field :ask_reason, :boolean, default: false
    field :max_open_per_player, :integer, default: 1
    # Who may open a ticket: "all", "playtime" (at least `min_playtime_hours`
    # on the server) or "vip".
    field :audience, :string, default: "all"
    field :min_playtime_hours, :integer, default: 2
    field :blocked_flags, {:array, :string}, default: []
    field :block_recent_bans, :boolean, default: false

    belongs_to :discord_webhook, HllConditionalActions.Discord.Webhook

    timestamps(type: :utc_datetime)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [
      :enabled,
      :commands,
      :cooldown_seconds,
      :auto_close_hours,
      :received_message,
      :reply_prefix,
      :closed_message,
      :attention_minutes,
      :max_per_hour,
      :quick_replies,
      :discord_webhook_id,
      :discord_mention_role_ids,
      :category_priorities,
      :default_priority,
      :status_word,
      :close_word,
      :hours_enabled,
      :hours_start,
      :hours_end,
      :hours_days,
      :offline_message,
      :hours_ranges,
      :category_colors,
      :category_order,
      :replies,
      :warn_before_close,
      :mention_min_priority,
      :accept_offline,
      :offline_alert_urgent,
      :ignore_case,
      :ask_reason,
      :max_open_per_player,
      :audience,
      :min_playtime_hours,
      :blocked_flags,
      :block_recent_bans
    ])
    |> update_change(:category_priorities, &normalize_categories/1)
    |> update_change(:category_colors, &normalize_colors/1)
    |> update_change(:category_order, &normalize_order/1)
    |> update_change(:replies, &normalize_reply_items/1)
    |> update_change(:hours_ranges, &normalize_ranges/1)
    |> update_change(:blocked_flags, &normalize_flags/1)
    |> validate_inclusion(:mention_min_priority, ~w(low normal high urgent))
    |> validate_inclusion(:audience, ~w(all playtime vip))
    |> validate_number(:max_open_per_player,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 5
    )
    |> validate_number(:min_playtime_hours,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 10_000
    )
    |> validate_length(:replies, max: 20)
    |> validate_inclusion(:default_priority, ~w(low normal high urgent))
    |> validate_categories()
    |> update_change(:status_word, &normalize_word/1)
    |> update_change(:close_word, &normalize_word/1)
    |> validate_length(:offline_message, max: @max_message)
    |> validate_subset(:hours_days, 1..7 |> Enum.to_list())
    |> validate_hours()
    |> update_change(:quick_replies, &normalize_replies/1)
    |> update_change(:commands, &normalize_commands/1)
    |> validate_commands()
    |> validate_number(:cooldown_seconds,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 3600
    )
    |> validate_number(:auto_close_hours, greater_than_or_equal_to: 0, less_than_or_equal_to: 168)
    |> validate_length(:received_message, max: @max_message)
    |> validate_length(:closed_message, max: @max_message)
    |> validate_length(:reply_prefix, max: 60)
    |> validate_number(:attention_minutes,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 1440
    )
    |> validate_number(:max_per_hour, greater_than_or_equal_to: 0, less_than_or_equal_to: 60)
    |> validate_length(:quick_replies, max: 20)
    |> validate_format(:discord_mention_role_ids, ~r/^[\d\s,]*$/,
      message: dgettext_noop("errors", "only role ids, separated by commas")
    )
    |> foreign_key_constraint(:discord_webhook_id)
  end

  # The colours a category can wear, in the order the picker offers them.
  @colors ~w(red amber lime teal lavender gray)

  @doc "The colour keys a category can take, in picker order."
  @spec colors() :: [String.t()]
  def colors, do: @colors

  @doc """
  The category names, in the order the admin gave them (then by name for
  any the order does not list).

      iex> alias HllConditionalActions.Tickets.Settings
      iex> Settings.categories(%Settings{category_priorities: %{"b" => "low", "a" => "low", "c" => "low"}, category_order: ["c"]})
      ["c", "a", "b"]
  """
  @spec categories(t()) :: [String.t()]
  def categories(%__MODULE__{category_priorities: map} = settings) do
    names = Map.keys(map || %{})
    order = settings.category_order || []
    listed = Enum.filter(order, &(&1 in names))
    listed ++ (names |> Enum.reject(&(&1 in listed)) |> Enum.sort())
  end

  @doc """
  The categories with their priority and colour, in order. A category
  without a colour gets one by its position.

      iex> alias HllConditionalActions.Tickets.Settings
      iex> Settings.category_list(%Settings{category_priorities: %{"tk" => "high"}, category_colors: %{}})
      [%{name: "tk", priority: "high", color: "red"}]
  """
  @spec category_list(t()) :: [%{name: String.t(), priority: String.t(), color: String.t()}]
  def category_list(%__MODULE__{} = settings) do
    colors = settings.category_colors || %{}

    settings
    |> categories()
    |> Enum.with_index()
    |> Enum.map(fn {name, index} ->
      %{
        name: name,
        priority: Map.get(settings.category_priorities, name, "normal"),
        color: color_for(Map.get(colors, name), index)
      }
    end)
  end

  @doc """
  A colour key that is one of `colors/0`, or the one for a position.

      iex> HllConditionalActions.Tickets.Settings.color_for(nil, 7)
      "amber"
      iex> HllConditionalActions.Tickets.Settings.color_for("teal", 0)
      "teal"
  """
  @spec color_for(term(), non_neg_integer()) :: String.t()
  def color_for(color, _index) when color in @colors, do: color
  def color_for(_color, index), do: Enum.at(@colors, rem(index, length(@colors)))

  @doc """
  The category a name stands for on these settings, ignoring case, or nil.

      iex> alias HllConditionalActions.Tickets.Settings
      iex> Settings.find_category(%Settings{category_priorities: %{"Tiro amigo" => "high"}}, "tiro AMIGO")
      "Tiro amigo"
  """
  @spec find_category(t(), String.t() | nil) :: String.t() | nil
  def find_category(_settings, nil), do: nil

  def find_category(%__MODULE__{category_priorities: map}, name) do
    wanted = name |> String.trim() |> String.downcase()
    Enum.find(Map.keys(map || %{}), &(String.downcase(&1) == wanted))
  end

  @doc """
  Cleans the category map: names trimmed with single spaces, blanks dropped,
  unknown priorities read as normal. The case is kept as the admin wrote it;
  matching ignores it.

      iex> HllConditionalActions.Tickets.Settings.normalize_categories(%{" Tiro  amigo " => "urgent", "" => "low", "tk" => "?"})
      %{"Tiro amigo" => "urgent", "tk" => "normal"}
  """
  @spec normalize_categories(map() | nil) :: map()
  def normalize_categories(nil), do: %{}

  def normalize_categories(map) when is_map(map) do
    for {name, priority} <- map,
        name = clean_name(name),
        name != "",
        into: %{} do
      priority = to_string(priority)
      {name, if(priority in ~w(low normal high urgent), do: priority, else: "normal")}
    end
  end

  defp clean_name(name), do: name |> to_string() |> String.split() |> Enum.join(" ")

  defp normalize_colors(nil), do: %{}

  defp normalize_colors(map) when is_map(map) do
    for {name, color} <- map, color in @colors, into: %{}, do: {clean_name(name), color}
  end

  defp normalize_order(nil), do: []

  defp normalize_order(names) when is_list(names),
    do: names |> Enum.map(&clean_name/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()

  @doc """
  Cleans the quick replies: a title (the start of the text when blank), the
  text, whether sending it closes the ticket. Rows without text are dropped.

      iex> HllConditionalActions.Tickets.Settings.normalize_reply_items([%{"title" => "", "body" => " On my way "}, %{"body" => ""}])
      [%{"title" => "On my way", "body" => "On my way", "closes" => false}]
  """
  @spec normalize_reply_items([map()] | nil) :: [map()]
  def normalize_reply_items(nil), do: []

  def normalize_reply_items(items) when is_list(items) do
    items
    |> Enum.map(fn item ->
      item = Map.new(item, fn {key, value} -> {to_string(key), value} end)
      body = item |> Map.get("body") |> to_string() |> String.trim() |> String.slice(0, 250)
      title = item |> Map.get("title") |> to_string() |> String.trim() |> String.slice(0, 40)

      %{
        "title" => if(title == "", do: String.slice(body, 0, 40), else: title),
        "body" => body,
        "closes" => Map.get(item, "closes") in [true, "true", "on"]
      }
    end)
    |> Enum.reject(&(&1["body"] == ""))
    |> Enum.uniq_by(& &1["title"])
  end

  @doc """
  The quick replies of these settings; older settings kept only the texts.

      iex> alias HllConditionalActions.Tickets.Settings
      iex> Settings.reply_items(%Settings{replies: [], quick_replies: ["On my way"]})
      [%{"title" => "On my way", "body" => "On my way", "closes" => false}]
  """
  @spec reply_items(t()) :: [map()]
  def reply_items(%__MODULE__{replies: [_ | _] = replies}), do: replies

  def reply_items(%__MODULE__{quick_replies: replies}),
    do: normalize_reply_items(Enum.map(replies || [], &%{"body" => &1}))

  @doc """
  Cleans office-hour ranges: weekday keys "1".."7", each a list of
  `["HH:MM", "HH:MM"]` with a valid start and end ("24:00" and "00:00" both
  close at midnight), sorted by start.

      iex> HllConditionalActions.Tickets.Settings.normalize_ranges(%{"3" => [["19:00", "24:00"], ["12:00", "14:00"]], "9" => [["1:00", "2:00"]], "1" => [["bad", "10:00"]]})
      %{"3" => [["12:00", "14:00"], ["19:00", "24:00"]]}
  """
  @spec normalize_ranges(map() | nil) :: map()
  def normalize_ranges(nil), do: %{}

  def normalize_ranges(map) when is_map(map) do
    for {day, ranges} <- map,
        day = to_string(day),
        day in ~w(1 2 3 4 5 6 7),
        ranges = clean_ranges(ranges),
        ranges != [],
        into: %{},
        do: {day, ranges}
  end

  defp clean_ranges(ranges) when is_list(ranges) do
    ranges
    |> Enum.flat_map(&clean_range/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp clean_ranges(_ranges), do: []

  defp clean_range([from, until]) do
    with {:ok, start} <- parse_minutes(from),
         {:ok, stop} <- parse_minutes(until),
         stop = if(stop == 0, do: 1440, else: stop),
         true <- stop != start do
      [[format_minutes(start), format_minutes(stop)]]
    else
      _invalid -> []
    end
  end

  defp clean_range(_other), do: []

  @doc """
  Minutes since midnight of an "HH:MM" text; "24:00" is 1440.

      iex> HllConditionalActions.Tickets.Settings.parse_minutes("18:30")
      {:ok, 1110}
      iex> HllConditionalActions.Tickets.Settings.parse_minutes("24:00")
      {:ok, 1440}
      iex> HllConditionalActions.Tickets.Settings.parse_minutes("25:00")
      :error
  """
  @spec parse_minutes(term()) :: {:ok, 0..1440} | :error
  def parse_minutes(text) when is_binary(text) do
    case Regex.run(~r/^(\d{1,2}):(\d{2})$/, String.trim(text)) do
      [_all, hours, minutes] ->
        {hours, minutes} = {String.to_integer(hours), String.to_integer(minutes)}

        cond do
          hours == 24 and minutes == 0 -> {:ok, 1440}
          hours < 24 and minutes < 60 -> {:ok, hours * 60 + minutes}
          true -> :error
        end

      _no ->
        :error
    end
  end

  def parse_minutes(%Time{hour: hour, minute: minute}), do: {:ok, hour * 60 + minute}
  def parse_minutes(_other), do: :error

  @doc """
  "HH:MM" of minutes since midnight.

      iex> HllConditionalActions.Tickets.Settings.format_minutes(1440)
      "24:00"
  """
  @spec format_minutes(0..1440) :: String.t()
  def format_minutes(minutes) do
    hours = minutes |> div(60) |> Integer.to_string() |> String.pad_leading(2, "0")
    rest = minutes |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{hours}:#{rest}"
  end

  @doc """
  The office hours as minutes per weekday: `%{1 => [{1080, 1440}], ...}`.
  Settings saved before ranges existed read their single window; a window
  that ends before it starts runs past midnight into the next day.

      iex> alias HllConditionalActions.Tickets.Settings
      iex> Settings.schedule(%Settings{hours_ranges: %{"2" => [["18:00", "24:00"]]}})
      %{2 => [{1080, 1440}]}
      iex> Settings.schedule(%Settings{hours_ranges: %{}, hours_start: ~T[20:00:00], hours_end: ~T[02:00:00], hours_days: [6]})
      %{6 => [{1200, 1440}], 7 => [{0, 120}]}
  """
  @spec schedule(t()) :: %{(1..7) => [{0..1440, 0..1440}]}
  def schedule(%__MODULE__{hours_ranges: ranges}) when is_map(ranges) and map_size(ranges) > 0 do
    Map.new(ranges, fn {day, list} ->
      {String.to_integer(to_string(day)),
       Enum.flat_map(list, fn [from, until] ->
         {:ok, start} = parse_minutes(from)
         {:ok, stop} = parse_minutes(until)
         split_range(start, stop)
       end)}
    end)
    |> spill_over()
  end

  def schedule(%__MODULE__{hours_start: %Time{} = from, hours_end: %Time{} = until} = settings) do
    {:ok, start} = parse_minutes(from)
    {:ok, stop} = parse_minutes(until)
    stop = if stop == 0, do: 1440, else: stop

    (settings.hours_days || [])
    |> Map.new(&{&1, split_range(start, stop)})
    |> spill_over()
  end

  def schedule(_settings), do: %{}

  # A range past midnight keeps its first part on its day and marks the rest
  # for the next one, which `spill_over/1` moves there.
  defp split_range(start, stop) when stop > start, do: [{start, stop}]
  defp split_range(start, stop), do: [{start, 1440}, {:next, stop}]

  defp spill_over(days) do
    Enum.reduce(days, %{}, fn {day, ranges}, acc ->
      {spill, own} = Enum.split_with(ranges, &match?({:next, _}, &1))
      next = if day == 7, do: 1, else: day + 1

      acc
      |> Map.update(day, own, &(&1 ++ own))
      |> then(fn acc -> Enum.reduce(spill, acc, &spill_into(&2, next, &1)) end)
    end)
    |> Map.new(fn {day, ranges} -> {day, Enum.sort(ranges)} end)
    |> Map.reject(fn {_day, ranges} -> ranges == [] end)
  end

  defp spill_into(acc, next, {:next, stop}),
    do: Map.update(acc, next, [{0, stop}], &[{0, stop} | &1])

  @doc """
  Cleans the CRCON flags that keep a player from opening tickets.

      iex> HllConditionalActions.Tickets.Settings.normalize_flags([" sem_ticket ", "", "sem_ticket"])
      ["sem_ticket"]
  """
  @spec normalize_flags([String.t()] | nil) :: [String.t()]
  def normalize_flags(nil), do: []

  def normalize_flags(flags) when is_list(flags),
    do: flags |> Enum.map(&String.trim(to_string(&1))) |> Enum.reject(&(&1 == "")) |> Enum.uniq()

  defp validate_categories(changeset) do
    names = changeset |> get_field(:category_priorities) |> Kernel.||(%{}) |> Map.keys()

    cond do
      length(names) > 20 ->
        add_error(changeset, :category_priorities, "at most 20 categories")

      Enum.any?(names, &(String.length(&1) > 30)) ->
        add_error(changeset, :category_priorities, "a category is at most 30 characters")

      true ->
        changeset
    end
  end

  defp normalize_word(nil), do: nil
  defp normalize_word(word), do: word |> String.trim() |> String.downcase()

  defp validate_hours(changeset) do
    ranges? = map_size(get_field(changeset, :hours_ranges) || %{}) > 0

    if get_field(changeset, :hours_enabled) and not ranges? and
         (is_nil(get_field(changeset, :hours_start)) or is_nil(get_field(changeset, :hours_end))) do
      add_error(changeset, :hours_start, "set when the office hours start and end")
    else
      changeset
    end
  end

  @doc """
  Cleans the quick replies: trimmed, without blanks or repeats, each at most
  250 characters (what fits a private message).

      iex> HllConditionalActions.Tickets.Settings.normalize_replies([" On my way ", "", "On my way"])
      ["On my way"]
  """
  @spec normalize_replies([String.t()] | nil) :: [String.t()]
  def normalize_replies(nil), do: []

  def normalize_replies(replies) when is_list(replies) do
    replies
    |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.slice(0, 250)))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  @doc """
  Cleans a list of commands: trimmed, lower-cased, without blanks or repeats.

      iex> HllConditionalActions.Tickets.Settings.normalize_commands([" !Admin ", "", "!admin", "!adm"])
      ["!admin", "!adm"]
  """
  @spec normalize_commands([String.t()] | nil) :: [String.t()]
  def normalize_commands(nil), do: []

  def normalize_commands(commands) when is_list(commands) do
    commands
    |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp validate_commands(changeset) do
    commands = get_field(changeset, :commands) || []

    cond do
      get_field(changeset, :enabled) and commands == [] ->
        add_error(changeset, :commands, dgettext_noop("errors", "add at least one command"))

      length(commands) > @max_commands ->
        add_error(changeset, :commands, dgettext_noop("errors", "at most 10 commands"))

      Enum.any?(commands, &String.contains?(&1, " ")) ->
        add_error(
          changeset,
          :commands,
          dgettext_noop("errors", "a command cannot contain spaces")
        )

      Enum.any?(commands, &(String.length(&1) > 30)) ->
        add_error(
          changeset,
          :commands,
          dgettext_noop("errors", "a command is at most 30 characters")
        )

      true ->
        changeset
    end
  end
end
