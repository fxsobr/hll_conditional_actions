defmodule HllConditionalActionsWeb.TicketSettingsForm do
  @moduledoc """
  The pieces of the ticket settings that both the settings page
  (`HllConditionalActionsWeb.TicketLive.Settings`) and the setup wizard
  (`HllConditionalActionsWeb.TicketLive.Setup`) draw: the switch, the
  category list with its colours, the quick replies, the in-game messages
  with their placeholders, and the office hours drawn per weekday.

  The form sends rows (`settings[categories][0][name]`, `settings[replies]`,
  `settings[hours][3][0][from]`) that `parse/1` turns into what
  `HllConditionalActions.Tickets.Settings` stores, and `rows/1` turns the
  stored settings back into rows for the page. Rows are kept as typed
  between keystrokes, blank ones included, until saved.
  """

  use HllConditionalActionsWeb, :html

  alias HllConditionalActions.Tickets.Settings

  # ── Data ───────────────────────────────────────────────────────────────────

  @doc """
  What a server that never saved settings starts from: suggestions in the
  admin's language, which the wizard shows and the admin can change.
  """
  @spec defaults(Settings.t()) :: Settings.t()
  def defaults(%Settings{id: nil} = settings) do
    categories = [
      {gettext("Friendly fire"), "high", "red"},
      {gettext("Behaviour"), "normal", "amber"},
      {gettext("Help question"), "low", "teal"},
      {gettext("Cheating"), "urgent", "lavender"},
      {"VIP", "normal", "lime"}
    ]

    %{
      settings
      | commands: ["!admin"],
        received_message:
          gettext(
            "Ticket \#{ticket_id} opened, {player_name}. An admin will answer you soon. Keep playing."
          ),
        reply_prefix: gettext("[\#{ticket_id}] {admin_name}: {message}"),
        closed_message:
          gettext("Ticket \#{ticket_id} closed. If you need anything, just use {command} again."),
        status_word: gettext("status"),
        close_word: gettext("close"),
        hours_start: ~T[18:00:00],
        hours_end: ~T[00:00:00],
        hours_ranges: Map.new(1..7, &{to_string(&1), [["18:00", "24:00"]]}),
        offline_message:
          gettext(
            "We are outside office hours now. Your ticket \#{ticket_id} is saved and we will answer as soon as we are back."
          ),
        category_priorities:
          Map.new(categories, fn {name, priority, _color} -> {name, priority} end),
        category_colors: Map.new(categories, fn {name, _priority, color} -> {name, color} end),
        category_order: Enum.map(categories, &elem(&1, 0)),
        replies: [
          %{
            "title" => gettext("I'm looking"),
            "body" => gettext("Thanks for the heads-up, {player_name}. I'm looking into it now."),
            "closes" => false
          },
          %{
            "title" => gettext("What is the player's name?"),
            "body" =>
              gettext("Send me the exact name of who did it, as it shows on the scoreboard."),
            "closes" => false
          },
          %{
            "title" => gettext("Solved, thank you"),
            "body" =>
              gettext("Solved, {player_name}. Thanks for letting us know, have a good game!"),
            "closes" => true
          }
        ]
    }
  end

  def defaults(settings), do: settings

  @doc """
  Splits the commands line into a list.

      iex> HllConditionalActionsWeb.TicketSettingsForm.split_commands("!admin, !adm  @help")
      ["!admin", "!adm", "@help"]
  """
  @spec split_commands(String.t() | nil) :: [String.t()]
  def split_commands(nil), do: []
  def split_commands(text), do: String.split(text, ~r/[\s,;]+/, trim: true)

  @doc """
  The form's params as the settings schema takes them. Fields a form did
  not send (a wizard step shows only some) are left alone.

      iex> alias HllConditionalActionsWeb.TicketSettingsForm
      iex> TicketSettingsForm.parse(%{
      ...>   "categories" => %{"0" => %{"name" => "TK", "priority" => "high", "color" => "red"}},
      ...>   "hours" => %{"3" => %{"0" => %{"from" => "12:00", "to" => "14:00"}}},
      ...>   "auto_close_on" => "false", "auto_close_hours" => "12"
      ...> })
      %{
        "auto_close_hours" => 0,
        "category_colors" => %{"TK" => "red"},
        "category_order" => ["TK"],
        "category_priorities" => %{"TK" => "high"},
        "hours_ranges" => %{"3" => [["12:00", "14:00"]]}
      }
  """
  @spec parse(map()) :: map()
  def parse(params) do
    params
    |> put_if(params, "commands_text", "commands", &split_commands/1)
    |> put_if(params, "commands", "commands", &list_param/1)
    |> put_if(params, "blocked_flags", "blocked_flags", &list_param/1)
    |> put_if(params, "categories", nil, fn _rows ->
      rows = category_rows(params)

      %{
        "category_priorities" => Map.new(rows, &{&1["name"], &1["priority"]}),
        "category_colors" => Map.new(rows, &{&1["name"], &1["color"]}),
        "category_order" => Enum.map(rows, & &1["name"])
      }
    end)
    |> put_if(params, "replies", "replies", fn _rows -> reply_rows(params) end)
    |> put_if(params, "hours", "hours_ranges", fn _days -> hour_rows(params) end)
    |> put_if(params, "auto_close_on", "auto_close_hours", fn
      "false" -> 0
      _on -> params["auto_close_hours"]
    end)
    |> put_if(params, "cooldown_choice", "cooldown_seconds", fn
      "other" -> params["cooldown_seconds"]
      minutes -> parse_int(minutes, 1) * 60
    end)
    |> Map.drop([
      "commands_text",
      "categories",
      "replies",
      "hours",
      "auto_close_on",
      "cooldown_choice"
    ])
  end

  defp put_if(acc, params, from, to, fun) do
    case Map.fetch(params, from) do
      {:ok, value} ->
        case fun.(value) do
          %{} = several when is_nil(to) -> Map.merge(acc, several)
          one -> Map.put(acc, to, one)
        end

      :error ->
        acc
    end
  end

  defp list_param(list) when is_list(list), do: Enum.reject(list, &(&1 == ""))
  defp list_param(%{} = map), do: map |> sorted_rows() |> Enum.reject(&(&1 == ""))
  defp list_param(text) when is_binary(text), do: split_commands(text)

  defp parse_int(text, default) do
    case Integer.parse(to_string(text)) do
      {value, _rest} -> value
      :error -> default
    end
  end

  # Indexed rows ("0", "1", ...) in index order, without the hidden "_" row.
  defp sorted_rows(map) when is_map(map) do
    map
    |> Enum.reject(fn {index, _row} -> index == "_" end)
    |> Enum.sort_by(fn {index, _row} -> parse_int(index, 0) end)
    |> Enum.map(&elem(&1, 1))
  end

  defp sorted_rows(_other), do: []

  @doc "The category rows of the form, as typed, in the order shown."
  @spec category_rows(map()) :: [map()]
  def category_rows(params) do
    params
    |> Map.get("categories", %{})
    |> sorted_rows()
    |> Enum.map(fn row ->
      %{
        "name" => String.trim(row["name"] || ""),
        "priority" => row["priority"] || "normal",
        "color" => row["color"] || "gray"
      }
    end)
  end

  @doc "The quick reply rows of the form, as typed."
  @spec reply_rows(map()) :: [map()]
  def reply_rows(params) do
    params
    |> Map.get("replies", %{})
    |> sorted_rows()
    |> Enum.map(fn row ->
      %{
        "title" => row["title"] || "",
        "body" => row["body"] || "",
        "closes" => row["closes"] in ["true", "on", true]
      }
    end)
  end

  @doc "The office hours of the form: weekday => [[from, to]]."
  @spec hour_rows(map()) :: map()
  def hour_rows(params) do
    params
    |> Map.get("hours", %{})
    |> Enum.reject(fn {day, _ranges} -> day == "_" end)
    |> Map.new(fn {day, ranges} ->
      {day, ranges |> sorted_rows() |> Enum.map(&[&1["from"] || "", &1["to"] || ""])}
    end)
  end

  @doc "The rows the page draws, from saved (or changed) settings."
  @spec rows(Settings.t()) :: %{categories: [map()], replies: [map()], hours: map()}
  def rows(%Settings{} = settings) do
    %{
      categories:
        Enum.map(Settings.category_list(settings), fn category ->
          %{"name" => category.name, "priority" => category.priority, "color" => category.color}
        end),
      replies: Settings.reply_items(settings),
      hours:
        settings
        |> Settings.schedule()
        |> Map.new(fn {day, ranges} ->
          {to_string(day),
           Enum.map(ranges, fn {from, to} ->
             [Settings.format_minutes(from), Settings.format_minutes(to)]
           end)}
        end)
    }
  end

  @doc false
  def parse_id(id) do
    case Integer.parse(to_string(id)) do
      {id, ""} -> [id]
      _other -> []
    end
  end

  @doc """
  Which parts of the settings a changeset changes, for "2 unsaved changes":
  a category edit counts once however many of its fields moved.
  """
  @spec changed_groups(Ecto.Changeset.t()) :: [atom()]
  def changed_groups(%Ecto.Changeset{changes: changes}) do
    changes
    |> Map.keys()
    |> Enum.map(fn
      field when field in [:category_priorities, :category_colors, :category_order] -> :categories
      field when field in [:replies, :quick_replies] -> :replies
      field when field in [:hours_ranges, :hours_start, :hours_end, :hours_days] -> :hours
      field -> field
    end)
    |> Enum.uniq()
  end

  @doc "The placeholders a message can use, in the order the chips show them."
  @spec variables() :: [String.t()]
  def variables, do: ~w({player_name} {ticket_id} {category} {admin_name} {server_name})

  @doc """
  A message template as the player would read it, with the placeholders
  filled with examples.

      iex> HllConditionalActionsWeb.TicketSettingsForm.sample("Hi {player}, type {command}", ["!ticket"], "Ana")
      "Hi Sarge, type !ticket"
  """
  @spec sample(String.t() | nil, [String.t()], String.t(), map()) :: String.t()
  def sample(text, commands, admin, extra \\ %{}) do
    vars =
      Map.merge(
        %{
          "player" => "Sarge",
          "player_name" => "Sarge",
          "command" => List.first(commands, "!admin"),
          "admin" => admin,
          "admin_name" => admin,
          "ticket_id" => "214",
          "category" => "TK",
          "server_name" => "HLL",
          "message" => gettext("On my way")
        },
        extra
      )

    HllConditionalActions.Tickets.fill(text || "", vars)
  end

  # ── Components ─────────────────────────────────────────────────────────────

  @doc """
  The on/off switch of the boards: a 44×26 track with a round knob.
  """
  attr :name, :string, required: true
  attr :checked, :boolean, default: false
  attr :label, :string, required: true
  attr :id, :string, default: nil
  attr :form, :string, default: nil

  def switch(assigns) do
    ~H"""
    <label class="relative inline-flex shrink-0 cursor-pointer" title={@label}>
      <input type="hidden" name={@name} value="false" form={@form} />
      <input
        type="checkbox"
        id={@id}
        name={@name}
        value="true"
        role="switch"
        checked={@checked}
        aria-label={@label}
        form={@form}
        class="peer sr-only"
      />
      <span class="flex h-[1.625rem] w-11 items-center rounded-full bg-base-300 p-[3px] transition-colors peer-checked:bg-primary peer-focus-visible:ring-2 peer-focus-visible:ring-primary/50 [&>span]:transition-transform peer-checked:[&>span]:translate-x-[1.125rem] peer-checked:[&>span]:bg-primary-content">
        <span class="size-5 rounded-full bg-muted"></span>
      </span>
    </label>
    """
  end

  @doc "A small pill for a priority, as the category list shows it."
  attr :priority, :string, required: true

  def priority_tag(assigns) do
    ~H"""
    <span class={[
      "shrink-0 rounded-full px-2 py-[3px] text-[0.6875rem] font-semibold",
      if(@priority in ["high", "urgent"],
        do: "bg-error/14 text-error",
        else: "bg-base-300 text-subtle"
      )
    ]}>
      {Labels.ticket_priority(HllConditionalActions.Tickets.Ticket.parse_priority(@priority))}
    </span>
    """
  end

  @doc """
  The categories: a row each with its colour, name and priority, one row
  open for editing at a time, reordered by dragging.
  """
  attr :rows, :list, required: true
  attr :editing, :any, default: nil, doc: "the index of the row being edited"
  attr :counts, :map, default: %{}, doc: "tickets this month, by lower-cased name"

  def category_editor(assigns) do
    ~H"""
    <div
      id="category-rows"
      phx-hook=".SortRows"
      data-event="reorder_categories"
      class="flex flex-col gap-2"
    >
      <input type="hidden" name="settings[categories][_][name]" value="" />
      <p
        :if={@rows == []}
        id="no-categories"
        class="rounded-[0.875rem] border border-dashed border-base-300 p-4 text-center text-sm text-muted"
      >
        {gettext("No category yet: every ticket opens at the default priority.")}
      </p>
      <%= for {row, index} <- Enum.with_index(@rows) do %>
        <div
          :if={index != @editing}
          id={"category-row-#{index}"}
          data-index={index}
          draggable="true"
          class={[
            "flex items-center gap-2.5 rounded-[0.875rem] bg-secondary py-2 pl-2.5 pr-2.5",
            "inbox-color-#{row["color"]}"
          ]}
        >
          <.icon name="hero-bars-2" class="size-3.5 shrink-0 cursor-grab text-muted" />
          <span class="inbox-swatch size-3 shrink-0 rounded"></span>
          <span class="min-w-0 flex-1 truncate text-sm font-medium">
            {if row["name"] == "", do: gettext("(no name)"), else: row["name"]}
          </span>
          <.priority_tag priority={row["priority"]} />
          <button
            type="button"
            phx-click="edit_category"
            phx-value-index={index}
            aria-label={gettext("Edit %{name}", name: row["name"])}
            class="flex size-[1.875rem] cursor-pointer items-center justify-center rounded-full text-muted transition-colors hover:bg-base-300 hover:text-base-content"
          >
            <.icon name="hero-pencil" class="size-3.5" />
          </button>
          <input type="hidden" name={"settings[categories][#{index}][name]"} value={row["name"]} />
          <input
            type="hidden"
            name={"settings[categories][#{index}][priority]"}
            value={row["priority"]}
          />
          <input type="hidden" name={"settings[categories][#{index}][color]"} value={row["color"]} />
        </div>
        <div
          :if={index == @editing}
          id={"category-row-#{index}"}
          data-index={index}
          class={[
            "flex flex-col gap-2.5 rounded-[0.875rem] border border-(--inbox-strong) bg-secondary px-2.5 pb-3 pt-2.5",
            "inbox-color-#{row["color"]}"
          ]}
        >
          <div class="flex items-center gap-2.5">
            <.icon name="hero-bars-2" class="size-3.5 shrink-0 text-muted" />
            <span class="inbox-swatch size-3 shrink-0 rounded"></span>
            <input
              type="text"
              id={"settings_categories_#{index}_name"}
              name={"settings[categories][#{index}][name]"}
              value={row["name"]}
              maxlength="30"
              phx-debounce="300"
              aria-label={gettext("Category name")}
              class="h-8 min-w-0 flex-1 rounded-[0.625rem] border border-(--inbox-strong) bg-base-100 px-2.5 text-sm outline-none focus:border-primary/60"
            />
            <select
              name={"settings[categories][#{index}][priority]"}
              aria-label={gettext("Priority")}
              class={[
                "h-7 shrink-0 cursor-pointer appearance-none rounded-full border-0 px-2.5 text-[0.6875rem] font-semibold outline-none",
                if(row["priority"] in ["high", "urgent"],
                  do: "bg-error/14 text-error",
                  else: "bg-base-300 text-subtle"
                )
              ]}
            >
              <option
                :for={{label, value} <- Labels.ticket_priority_options()}
                value={value}
                selected={value == row["priority"]}
              >
                {label}
              </option>
            </select>
          </div>
          <div
            role="radiogroup"
            aria-label={gettext("Category colour")}
            class="flex items-center gap-2 pl-6"
          >
            <label
              :for={color <- Settings.colors()}
              class={["cursor-pointer", "inbox-color-#{color}"]}
            >
              <input
                type="radio"
                name={"settings[categories][#{index}][color]"}
                value={color}
                checked={color == row["color"]}
                class="peer sr-only"
              />
              <span
                title={color_label(color)}
                class="inbox-swatch block size-[1.375rem] rounded-full peer-checked:shadow-[0_0_0_2px_var(--color-secondary),0_0_0_4px_var(--color-base-content)] peer-focus-visible:ring-2 peer-focus-visible:ring-primary/50"
              >
                <span class="sr-only">{color_label(color)}</span>
              </span>
            </label>
            <span class="flex-1"></span>
            <span class="text-xs text-muted">
              {ngettext(
                "1 this month",
                "%{count} this month",
                Map.get(@counts, String.downcase(row["name"]), 0)
              )}
            </span>
            <button
              type="button"
              phx-click="remove_category"
              phx-value-index={index}
              aria-label={gettext("Remove")}
              class="flex size-7 cursor-pointer items-center justify-center rounded-full text-muted hover:bg-base-300 hover:text-error"
            >
              <.icon name="hero-trash" class="size-3.5" />
            </button>
          </div>
        </div>
      <% end %>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".SortRows">
      export default {
        mounted() {
          this.el.addEventListener("dragstart", (e) => {
            const row = e.target.closest("[data-index]")
            if (!row) return
            this.dragged = row
            e.dataTransfer.effectAllowed = "move"
            row.classList.add("opacity-50")
          })
          this.el.addEventListener("dragend", () => {
            if (this.dragged) this.dragged.classList.remove("opacity-50")
            this.dragged = null
          })
          this.el.addEventListener("dragover", (e) => {
            if (!this.dragged) return
            e.preventDefault()
            const over = e.target.closest("[data-index]")
            if (!over || over === this.dragged) return
            const box = over.getBoundingClientRect()
            const after = e.clientY > box.top + box.height / 2
            over.parentNode.insertBefore(this.dragged, after ? over.nextSibling : over)
          })
          this.el.addEventListener("drop", (e) => {
            if (!this.dragged) return
            e.preventDefault()
            const order = [...this.el.querySelectorAll(":scope > [data-index]")].map((row) => row.dataset.index)
            this.pushEvent(this.el.dataset.event, {order})
          })
        }
      }
    </script>
    """
  end

  defp color_label("red"), do: gettext("Red")
  defp color_label("amber"), do: gettext("Amber")
  defp color_label("lime"), do: gettext("Lime")
  defp color_label("teal"), do: gettext("Teal")
  defp color_label("lavender"), do: gettext("Lavender")
  defp color_label(_gray), do: gettext("Grey")

  @doc """
  The quick replies: title and text, how often each was used, one open for
  editing at a time.
  """
  attr :rows, :list, required: true
  attr :editing, :any, default: nil
  attr :uses, :map, default: %{}

  def replies_editor(assigns) do
    ~H"""
    <div id="reply-rows" phx-hook=".SortRows" data-event="reorder_replies" class="flex flex-col gap-2">
      <input type="hidden" name="settings[replies][_][body]" value="" />
      <p
        :if={@rows == []}
        class="rounded-[0.875rem] border border-dashed border-base-300 p-4 text-center text-sm text-muted"
      >
        {gettext("No quick reply yet.")}
      </p>
      <%= for {row, index} <- Enum.with_index(@rows) do %>
        <div
          :if={index != @editing}
          id={"reply-row-#{index}"}
          data-index={index}
          draggable="true"
          phx-click="edit_reply"
          phx-value-index={index}
          class="grid cursor-pointer grid-cols-[0.875rem_minmax(0,1fr)_auto] items-center gap-2.5 rounded-[0.875rem] bg-secondary px-3 py-2.5 transition-colors hover:bg-base-300/60"
        >
          <.icon name="hero-bars-2" class="size-3.5 cursor-grab text-muted" />
          <span class="flex min-w-0 flex-col gap-0.5">
            <strong class="truncate text-sm font-semibold">
              {if row["title"] == "", do: gettext("(no title)"), else: row["title"]}
            </strong>
            <span class="truncate text-xs text-muted">{row["body"]}</span>
          </span>
          <span class="text-xs text-muted">
            {gettext("used %{count}×", count: Map.get(@uses, row["title"], 0))}
          </span>
          <input type="hidden" name={"settings[replies][#{index}][title]"} value={row["title"]} />
          <input type="hidden" name={"settings[replies][#{index}][body]"} value={row["body"]} />
          <input
            type="hidden"
            name={"settings[replies][#{index}][closes]"}
            value={to_string(row["closes"])}
          />
        </div>
        <div
          :if={index == @editing}
          id={"reply-row-#{index}"}
          data-index={index}
          class="flex flex-col gap-2.5 rounded-[0.875rem] border border-(--inbox-strong) bg-secondary p-3"
        >
          <input
            type="text"
            id={"settings_replies_#{index}_title"}
            name={"settings[replies][#{index}][title]"}
            value={row["title"]}
            maxlength="40"
            phx-debounce="300"
            aria-label={gettext("Reply title")}
            class="h-9 rounded-[0.625rem] border border-(--inbox-strong) bg-base-100 px-3 text-sm font-semibold outline-none focus:border-primary/60"
          />
          <textarea
            id={"settings_replies_#{index}_body"}
            name={"settings[replies][#{index}][body]"}
            rows="2"
            maxlength="250"
            phx-debounce="300"
            aria-label={gettext("Reply text")}
            class="resize-none rounded-[0.625rem] border border-(--inbox-strong) bg-base-100 px-3 py-2.5 font-mono text-[0.8125rem] leading-normal outline-none focus:border-primary/60"
          >{row["body"]}</textarea>
          <div class="flex flex-wrap items-center gap-1.5">
            <label class="mr-auto flex cursor-pointer items-center gap-2 text-xs text-subtle">
              <input type="hidden" name={"settings[replies][#{index}][closes]"} value="false" />
              <input
                type="checkbox"
                name={"settings[replies][#{index}][closes]"}
                value="true"
                checked={row["closes"]}
                class="size-4 accent-[var(--color-primary)]"
              />
              {gettext("Closes the ticket when sent")}
            </label>
            <button
              type="button"
              phx-click="remove_reply"
              phx-value-index={index}
              class="h-8 cursor-pointer rounded-full px-3 text-xs text-error hover:bg-error/10"
            >
              {gettext("Remove")}
            </button>
            <button
              type="button"
              phx-click="edit_reply"
              phx-value-index=""
              class="h-8 cursor-pointer rounded-full border border-base-300 bg-base-100 px-3.5 text-xs transition-colors hover:border-base-content/30"
            >
              {gettext("Done editing")}
            </button>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  @doc """
  One in-game message: open, it is a textarea with its counter and the
  placeholder chips; closed, one line of it that opens on click.
  """
  attr :field, :any, required: true
  attr :tag, :string, required: true
  attr :tone, :string, required: true, values: ~w(warning engine neutral)
  attr :hint, :string, required: true
  attr :open, :boolean, default: false
  attr :key, :string, required: true
  attr :max, :integer, default: 300

  def message_editor(assigns) do
    assigns = assign(assigns, :value, assigns.field.value || "")

    ~H"""
    <div
      :if={@open}
      id={"message-#{@key}"}
      class="flex flex-col gap-2 rounded-2xl border border-(--inbox-strong) bg-secondary p-3"
    >
      <div class="flex items-center gap-2">
        <span class={tag_class(@tone)}>{@tag}</span>
        <span class="flex-1 text-[0.8125rem] text-subtle">{@hint}</span>
        <span class="font-mono text-[0.6875rem] text-muted">
          {String.length(@value)}/{@max}
        </span>
      </div>
      <textarea
        id={@field.id}
        name={@field.name}
        rows="2"
        maxlength={@max}
        phx-debounce="300"
        aria-label={@tag}
        class="resize-none rounded-[0.625rem] border border-(--inbox-strong) bg-base-100 px-3 py-2.5 font-mono text-xs leading-normal outline-none focus:border-primary/60"
      >{@value}</textarea>
      <div
        id={"message-#{@key}-vars"}
        phx-hook=".InsertVariable"
        data-target={@field.id}
        class="flex flex-wrap gap-1.5"
      >
        <button
          :for={variable <- variables()}
          type="button"
          data-variable={variable}
          class="h-7 cursor-pointer rounded-lg border border-(--inbox-field-line) bg-base-100 px-2.5 font-mono text-[0.6875rem] text-subtle transition-colors hover:text-base-content"
        >
          {variable}
        </button>
      </div>
      <p :for={error <- @field.errors} class="text-xs text-error">{translate_error(error)}</p>
    </div>
    <button
      :if={!@open}
      type="button"
      id={"message-#{@key}"}
      phx-click="open_message"
      phx-value-key={@key}
      class="flex cursor-pointer flex-col gap-1 rounded-2xl bg-secondary p-3 text-left transition-colors hover:bg-base-300/60"
    >
      <span class="flex items-center gap-2">
        <span class={tag_class(@tone)}>{@tag}</span>
        <span class="text-[0.8125rem] text-subtle">{@hint}</span>
      </span>
      <span class="truncate font-mono text-xs text-subtle">
        {if @value == "", do: gettext("(nothing is sent)"), else: @value}
      </span>
      <input type="hidden" name={@field.name} value={@value} />
    </button>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".InsertVariable">
      export default {
        mounted() {
          this.el.addEventListener("click", (e) => {
            const button = e.target.closest("[data-variable]")
            if (!button) return
            const field = document.getElementById(this.el.dataset.target)
            if (!field) return
            const start = field.selectionStart ?? field.value.length
            const end = field.selectionEnd ?? field.value.length
            const text = button.dataset.variable
            field.value = field.value.slice(0, start) + text + field.value.slice(end)
            field.focus()
            field.setSelectionRange(start + text.length, start + text.length)
            field.dispatchEvent(new Event("input", {bubbles: true}))
          })
        }
      }
    </script>
    """
  end

  @doc false
  def tag_class(tone) do
    [
      "shrink-0 rounded-full px-2 py-[3px] text-[0.6875rem] font-semibold",
      case tone do
        "warning" -> "bg-warning/13 text-warning"
        "engine" -> "bg-accent/13 text-accent"
        _neutral -> "bg-base-300 text-subtle"
      end
    ]
  end

  @doc """
  The office hours, a bar per weekday with its ranges, today marked with
  the current time; a day opens to edit its ranges.
  """
  attr :hours, :map, required: true, doc: "weekday (\"1\"..\"7\") => [[from, to]]"
  attr :editing, :any, default: nil, doc: "the weekday being edited"
  attr :now, :any, default: nil, doc: "the local {weekday, minute} to mark"

  def hours_editor(assigns) do
    ~H"""
    <div id="hours-days" class="flex flex-col gap-1.5">
      <input type="hidden" name="settings[hours][_]" value="" />
      <%= for day <- 1..7, key = to_string(day), ranges = Map.get(@hours, key, []) do %>
        <button
          type="button"
          id={"hours-day-#{day}"}
          phx-click="edit_day"
          phx-value-day={day}
          aria-expanded={to_string(@editing == key)}
          class="grid cursor-pointer grid-cols-[2.125rem_minmax(0,1fr)_7.375rem] items-center gap-2.5 text-left"
        >
          <span class={[
            "text-[0.8125rem]",
            if(@now && elem(@now, 0) == day,
              do: "font-semibold text-base-content",
              else: "text-subtle"
            )
          ]}>
            {weekday(day)}
          </span>
          <span class="relative block h-[1.625rem] rounded-[0.4375rem] bg-secondary">
            <span
              :for={{left, width} <- spans(ranges)}
              class="absolute inset-y-0 rounded-[0.4375rem] bg-primary/45"
              style={"left: #{left}%; width: #{width}%"}
            ></span>
            <span
              :if={@now && elem(@now, 0) == day}
              class="absolute -inset-y-1 w-0.5 rounded-sm bg-base-content"
              style={"left: #{Float.round(elem(@now, 1) / 14.4, 2)}%"}
              title={gettext("now")}
            ></span>
          </span>
          <span class={[
            "font-mono",
            if(length(ranges) > 1, do: "text-[0.6875rem] leading-[1.3]", else: "text-xs")
          ]}>
            <%= if ranges == [] do %>
              <span class="text-muted">{gettext("closed")}</span>
            <% else %>
              <span :for={[from, to] <- ranges} class="block">{from}–{midnight(to)}</span>
            <% end %>
          </span>
        </button>
        <div :for={{[from, to], index} <- Enum.with_index(ranges)} class="hidden">
          <input
            :if={@editing != key}
            type="hidden"
            name={"settings[hours][#{key}][#{index}][from]"}
            value={from}
          />
          <input
            :if={@editing != key}
            type="hidden"
            name={"settings[hours][#{key}][#{index}][to]"}
            value={to}
          />
        </div>
        <div
          :if={@editing == key}
          id={"hours-edit-#{day}"}
          class="ml-11 flex flex-col gap-2 rounded-2xl bg-secondary p-3"
        >
          <div :for={{[from, to], index} <- Enum.with_index(ranges)} class="flex items-center gap-2">
            <input
              type="time"
              name={"settings[hours][#{key}][#{index}][from]"}
              value={from}
              aria-label={gettext("From")}
              class="h-9 rounded-[0.625rem] border border-(--inbox-strong) bg-base-100 px-2 font-mono text-xs"
            />
            <span class="text-muted">–</span>
            <input
              type="text"
              name={"settings[hours][#{key}][#{index}][to]"}
              value={to}
              pattern="\d{1,2}:\d{2}"
              aria-label={gettext("Until")}
              class="h-9 w-20 rounded-[0.625rem] border border-(--inbox-strong) bg-base-100 px-2 font-mono text-xs"
            />
            <button
              type="button"
              phx-click="remove_range"
              phx-value-day={key}
              phx-value-index={index}
              aria-label={gettext("Remove")}
              class="flex size-8 cursor-pointer items-center justify-center rounded-full text-muted hover:bg-base-300 hover:text-error"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>
          <p :if={ranges == []} class="text-xs text-muted">{gettext("Closed all day.")}</p>
          <p class="text-[0.6875rem] text-muted">{gettext("24:00 closes at midnight.")}</p>
        </div>
      <% end %>
      <div class="grid grid-cols-[2.125rem_minmax(0,1fr)_7.375rem] gap-2.5">
        <span></span>
        <span class="flex justify-between font-mono text-[0.625rem] text-muted" aria-hidden="true">
          <span>0h</span><span>6h</span><span>12h</span><span>18h</span><span>24h</span>
        </span>
        <span></span>
      </div>
    </div>
    """
  end

  # The end of a range as the boards write it: midnight is 00:00.
  defp midnight("24:00"), do: "00:00"
  defp midnight(time), do: time

  @doc "The short name of a weekday, 1 Monday .. 7 Sunday."
  @spec weekday(1..7) :: String.t()
  def weekday(1), do: String.downcase(gettext("Mon"))
  def weekday(2), do: String.downcase(gettext("Tue"))
  def weekday(3), do: String.downcase(gettext("Wed"))
  def weekday(4), do: String.downcase(gettext("Thu"))
  def weekday(5), do: String.downcase(gettext("Fri"))
  def weekday(6), do: String.downcase(gettext("Sat"))
  def weekday(7), do: String.downcase(gettext("Sun"))

  @doc """
  Where a day's ranges sit on a 24-hour bar, as `{left, width}` percentages.
  A range past midnight runs to the end of the bar.

      iex> HllConditionalActionsWeb.TicketSettingsForm.spans([["18:00", "24:00"], ["12:00", "14:00"]])
      [{75.0, 25.0}, {50.0, 8.33}]
      iex> HllConditionalActionsWeb.TicketSettingsForm.spans([["20:00", "02:00"], ["x", "y"]])
      [{83.33, 16.67}]
  """
  @spec spans([[String.t()]]) :: [{float(), float()}]
  def spans(ranges) do
    Enum.flat_map(ranges, &span/1)
  end

  defp span([from, to]) do
    with {:ok, start} <- Settings.parse_minutes(from),
         {:ok, stop} <- Settings.parse_minutes(to) do
      stop = if stop <= start, do: 1440, else: stop
      [{Float.round(start / 14.4, 2), Float.round((stop - start) / 14.4, 2)}]
    else
      _invalid -> []
    end
  end

  defp span(_other), do: []

  @doc """
  "seg a sex, 18h à 0h": the office hours in a few words, for messages and
  the metrics page. Days that share the same ranges are grouped.
  """
  @spec summary(map()) :: String.t()
  def summary(hours) do
    hours
    |> Enum.reject(fn {_day, ranges} -> ranges == [] end)
    |> Enum.group_by(fn {_day, ranges} -> ranges end, fn {day, _ranges} -> parse_int(day, 1) end)
    |> Enum.sort_by(fn {_ranges, days} -> Enum.min(days) end)
    |> Enum.map_join("; ", fn {ranges, days} ->
      "#{day_span(Enum.sort(days))}, " <> Enum.map_join(ranges, gettext(" and "), &range_words/1)
    end)
  end

  defp day_span([day]), do: weekday(day)

  defp day_span(days) do
    if List.last(days) - hd(days) == length(days) - 1,
      do: gettext("%{from} to %{to}", from: weekday(hd(days)), to: weekday(List.last(days))),
      else: Enum.map_join(days, ", ", &weekday/1)
  end

  defp range_words([from, to]),
    do: gettext("%{from} to %{to}", from: hour_word(from), to: hour_word(to))

  defp hour_word(text) do
    case Settings.parse_minutes(text) do
      {:ok, 1440} -> "0h"
      {:ok, minutes} when rem(minutes, 60) == 0 -> "#{div(minutes, 60)}h"
      {:ok, minutes} -> "#{div(minutes, 60)}h#{String.pad_leading("#{rem(minutes, 60)}", 2, "0")}"
      :error -> text
    end
  end
end
