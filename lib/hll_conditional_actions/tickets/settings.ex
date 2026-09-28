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
      :offline_message
    ])
    |> update_change(:category_priorities, &normalize_categories/1)
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

  @doc """
  The category names, sorted.
  """
  @spec categories(t()) :: [String.t()]
  def categories(%__MODULE__{category_priorities: map}), do: map |> Map.keys() |> Enum.sort()

  @doc """
  Cleans the category map: names trimmed and lower-cased, blanks dropped,
  unknown priorities read as normal.

      iex> HllConditionalActions.Tickets.Settings.normalize_categories(%{" Cheat " => "urgent", "" => "low", "tk" => "?"})
      %{"cheat" => "urgent", "tk" => "normal"}
  """
  @spec normalize_categories(map() | nil) :: map()
  def normalize_categories(nil), do: %{}

  def normalize_categories(map) when is_map(map) do
    for {name, priority} <- map,
        name = name |> to_string() |> String.trim() |> String.downcase(),
        name != "",
        into: %{} do
      priority = to_string(priority)
      {name, if(priority in ~w(low normal high urgent), do: priority, else: "normal")}
    end
  end

  defp validate_categories(changeset) do
    names = changeset |> get_field(:category_priorities) |> Kernel.||(%{}) |> Map.keys()

    cond do
      length(names) > 20 ->
        add_error(changeset, :category_priorities, "at most 20 categories")

      Enum.any?(names, &String.contains?(&1, " ")) ->
        add_error(changeset, :category_priorities, "a category is one word")

      true ->
        changeset
    end
  end

  defp normalize_word(nil), do: nil
  defp normalize_word(word), do: word |> String.trim() |> String.downcase()

  defp validate_hours(changeset) do
    if get_field(changeset, :hours_enabled) and
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
