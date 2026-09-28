defmodule HllConditionalActionsWeb.TicketSettingsForm do
  @moduledoc """
  The ticket settings form, cut into sections that both the settings page
  (one section at a time, behind tabs) and the setup wizard (one section
  per step) render.

  Every section is always in the DOM; the ones not showing are hidden, so a
  save sends the whole form whichever tab is open. The helpers here turn the
  form's text fields (commands on one line, quick replies one per line,
  category rows) into what `HllConditionalActions.Tickets.Settings` stores,
  and back.
  """

  use HllConditionalActionsWeb, :html

  alias HllConditionalActions.Tickets.Settings

  @sections [:general, :categories, :messages, :replies, :schedule, :limits, :discord]

  # Which stored fields each section edits, to point at the section that has
  # an error and to check one wizard step at a time.
  @fields %{
    general: [:enabled, :commands, :status_word, :close_word],
    categories: [:category_priorities, :default_priority],
    messages: [:received_message, :reply_prefix, :closed_message],
    replies: [:quick_replies],
    schedule: [:hours_enabled, :hours_start, :hours_end, :hours_days, :offline_message],
    limits: [:cooldown_seconds, :max_per_hour, :auto_close_hours, :attention_minutes],
    discord: [:discord_webhook_id, :discord_mention_role_ids]
  }

  @doc "Every section, in order."
  @spec sections() :: [atom()]
  def sections, do: @sections

  @doc "The fields a section edits."
  @spec fields(atom()) :: [atom()]
  def fields(section), do: Map.fetch!(@fields, section)

  @doc "A section's title."
  @spec title(atom()) :: String.t()
  def title(:general), do: gettext("Commands")
  def title(:categories), do: gettext("Categories")
  def title(:messages), do: gettext("Messages")
  def title(:replies), do: gettext("Quick replies")
  def title(:schedule), do: gettext("Office hours")
  def title(:limits), do: gettext("Limits and alerts")
  def title(:discord), do: gettext("Discord")

  @doc "A section's one-line explanation."
  @spec hint(atom()) :: String.t()
  def hint(:general), do: gettext("What players type in the game chat to call an admin")
  def hint(:categories), do: gettext("Sort calls by subject and give each its priority")
  def hint(:messages), do: gettext("What the player reads in game, and how answers are signed")
  def hint(:replies), do: gettext("Answers one click away on every ticket")
  def hint(:schedule), do: gettext("When a player can expect an answer")
  def hint(:limits), do: gettext("Stop spam, close silent tickets, raise the alarm")
  def hint(:discord), do: gettext("Announce new tickets in a Discord channel")

  @doc "A section's icon."
  @spec icon_name(atom()) :: String.t()
  def icon_name(:general), do: "hero-command-line"
  def icon_name(:categories), do: "hero-tag"
  def icon_name(:messages), do: "hero-chat-bubble-left-right"
  def icon_name(:replies), do: "hero-bolt"
  def icon_name(:schedule), do: "hero-clock"
  def icon_name(:limits), do: "hero-shield-check"
  def icon_name(:discord), do: "hero-megaphone"

  @doc """
  How many errors a changeset has in a section's fields, once it has been
  validated.
  """
  @spec error_count(Phoenix.HTML.Form.t(), atom()) :: non_neg_integer()
  def error_count(%{source: %Ecto.Changeset{action: nil}}, _section), do: 0

  def error_count(%{source: %Ecto.Changeset{errors: errors}}, section),
    do: Enum.count(errors, fn {field, _error} -> field in fields(section) end)

  def error_count(_form, _section), do: 0

  # ── Data ───────────────────────────────────────────────────────────────────

  @doc """
  What a server that never saved settings starts from: suggestions in the
  admin's language. Categories start empty; they are the community's own.
  """
  @spec defaults(Settings.t()) :: Settings.t()
  def defaults(%Settings{id: nil} = settings) do
    %{
      settings
      | commands: ["!admin"],
        received_message:
          gettext(
            "Your call was received. An admin will answer here soon. Keep typing to add details."
          ),
        reply_prefix: gettext("[ADMIN {admin}]"),
        closed_message:
          gettext("Your ticket was closed. Type {command} again if you still need help."),
        status_word: gettext("status"),
        close_word: gettext("close"),
        hours_start: ~T[18:00:00],
        hours_end: ~T[23:59:00],
        offline_message:
          gettext(
            "No admin is online right now. Leave your message here and we will answer as soon as we can."
          ),
        quick_replies: [
          gettext("I'm on my way to check."),
          gettext("Can you send a screenshot or clip on our Discord?"),
          gettext("Player punished. Thanks for the report!"),
          gettext("We could not find anything wrong. Let us know if it happens again.")
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
  """
  @spec parse(map()) :: map()
  def parse(params) do
    params
    |> put_if(params, "commands_text", "commands", &split_commands/1)
    |> put_if(params, "quick_replies_text", "quick_replies", &String.split(&1, ~r/\R/))
    |> put_if(params, "category_rows", "category_priorities", fn _rows ->
      Map.new(rows(params), &{&1["name"], &1["priority"]})
    end)
    |> put_if(params, "hours_days", "hours_days", fn days -> Enum.flat_map(days, &parse_id/1) end)
    |> Map.drop(["commands_text", "quick_replies_text", "category_rows"])
  end

  defp put_if(acc, params, from, to, fun) do
    case Map.fetch(params, from) do
      {:ok, value} -> Map.put(acc, to, fun.(value))
      :error -> acc
    end
  end

  @doc "The category rows of the form, in the order shown."
  @spec rows(map()) :: [map()]
  def rows(params) do
    params
    |> Map.get("category_rows", %{})
    |> Enum.reject(fn {index, _row} -> index == "_" end)
    |> Enum.sort_by(fn {index, _row} -> String.to_integer(index) end)
    |> Enum.map(fn {_index, row} ->
      %{"name" => row["name"] || "", "priority" => row["priority"] || "normal"}
    end)
  end

  @doc "The rows for a settings map."
  @spec rows_for(map() | nil) :: [map()]
  def rows_for(map) do
    (map || %{})
    |> Enum.sort()
    |> Enum.map(fn {name, priority} -> %{"name" => name, "priority" => priority} end)
  end

  @doc false
  def parse_id(id) do
    case Integer.parse(to_string(id)) do
      {id, ""} -> [id]
      _other -> []
    end
  end

  @doc """
  The assigns a form needs, from a changeset.
  """
  @spec assign_form(Phoenix.LiveView.Socket.t(), Ecto.Changeset.t()) ::
          Phoenix.LiveView.Socket.t()
  def assign_form(socket, changeset) do
    get = &Ecto.Changeset.get_field(changeset, &1)

    socket
    |> Phoenix.Component.assign(:form, to_form(changeset, as: :settings))
    |> Phoenix.Component.assign(:commands, get.(:commands) || [])
    |> Phoenix.Component.assign(:commands_text, Enum.join(get.(:commands) || [], " "))
    |> Phoenix.Component.assign(:quick_replies_text, Enum.join(get.(:quick_replies) || [], "\n"))
    |> Phoenix.Component.assign(:category_rows, rows_for(get.(:category_priorities)))
    |> Phoenix.Component.assign(:hours_days, get.(:hours_days) || [])
  end

  @doc """
  A message template as the player would read it, with the placeholders
  filled with examples.

      iex> HllConditionalActionsWeb.TicketSettingsForm.sample("Hi {player}, type {command}", ["!ticket"], "Ana")
      "Hi Sarge, type !ticket"
  """
  @spec sample(String.t() | nil, [String.t()], String.t()) :: String.t()
  def sample(text, commands, admin) do
    (text || "")
    |> String.replace("{player}", "Sarge")
    |> String.replace("{command}", List.first(commands, "!admin"))
    |> String.replace("{admin}", admin)
  end

  defp weekdays do
    [
      {gettext("Mon"), 1},
      {gettext("Tue"), 2},
      {gettext("Wed"), 3},
      {gettext("Thu"), 4},
      {gettext("Fri"), 5},
      {gettext("Sat"), 6},
      {gettext("Sun"), 7}
    ]
  end

  # ── Components ─────────────────────────────────────────────────────────────

  @doc """
  The navigation between sections: a column on wide screens, a scrolling
  row on phones. Each entry shows how many errors its section holds.
  """
  attr :current, :atom, required: true
  attr :form, :any, required: true
  attr :event, :string, default: "section"

  def section_nav(assigns) do
    ~H"""
    <nav
      id="settings-sections"
      aria-label={gettext("Settings sections")}
      class="-mx-1 flex gap-1 overflow-x-auto px-1 pb-1 lg:mx-0 lg:flex-col lg:overflow-visible lg:px-0"
    >
      <button
        :for={section <- sections()}
        type="button"
        phx-click={@event}
        phx-value-section={section}
        aria-current={@current == section && "page"}
        data-section={section}
        class={[
          "group flex shrink-0 cursor-pointer items-center gap-2.5 rounded-field px-3 py-2 text-left text-sm transition-colors",
          if(@current == section,
            do: "bg-primary/10 font-medium text-primary",
            else: "text-subtle hover:bg-base-200 hover:text-base-content"
          )
        ]}
      >
        <.icon name={icon_name(section)} class="size-4 shrink-0" />
        <span class="whitespace-nowrap">{title(section)}</span>
        <span
          :if={error_count(@form, section) > 0}
          class="ml-auto rounded-full bg-error px-1.5 text-xs font-semibold leading-5 text-error-content"
        >
          {error_count(@form, section)}
        </span>
      </button>
    </nav>
    """
  end

  @doc """
  One section of the form. `visible` false keeps it in the DOM, hidden, so
  its fields are still submitted.
  """
  attr :name, :atom, required: true
  attr :visible, :boolean, default: true
  attr :form, :any, required: true
  attr :commands, :list, required: true
  attr :commands_text, :string, required: true
  attr :quick_replies_text, :string, required: true
  attr :category_rows, :list, required: true
  attr :hours_days, :list, required: true
  attr :webhooks, :list, default: []
  attr :admin_name, :string, default: "Ana"
  attr :multi?, :boolean, default: false
  attr :show_header, :boolean, default: true

  def section(assigns) do
    ~H"""
    <section
      id={"settings-section-#{@name}"}
      class={["space-y-5", !@visible && "hidden"]}
      aria-hidden={!@visible && "true"}
    >
      <header :if={@show_header} class="border-b border-base-300 pb-3">
        <h2 class="text-title-medium flex items-center gap-2">
          <.icon name={icon_name(@name)} class="size-5 text-primary" />
          {title(@name)}
        </h2>
        <p class="mt-0.5 text-sm text-muted">{hint(@name)}</p>
      </header>
      {section_body(assigns)}
    </section>
    """
  end

  defp section_body(%{name: :general} = assigns) do
    ~H"""
    <.input
      field={@form[:enabled]}
      type="switch"
      label={
        if @multi?,
          do: gettext("Tickets are on for the selected servers"),
          else: gettext("Tickets are on for this server")
      }
    />

    <div>
      <.input
        name="settings[commands_text]"
        id="settings_commands_text"
        value={@commands_text}
        type="text"
        label={gettext("Commands")}
        placeholder="!admin !adm"
        help_text={
          gettext(
            "One or more, separated by spaces or commas. It must be the first word of the chat message; the rest becomes the ticket's text."
          )
        }
      />
      <p
        :for={error <- @form[:commands].errors}
        :if={@form.source.action}
        class="mt-1 text-sm text-error"
      >
        {translate_error(error)}
      </p>
      <div :if={@commands != []} class="mt-2 flex flex-wrap gap-1" id="command-preview">
        <.tone_badge :for={command <- @commands} tone="primary">{command}</.tone_badge>
      </div>
    </div>

    <div class="rounded-box border border-base-300 p-4">
      <p class="text-sm font-medium">{gettext("Commands for the player")}</p>
      <p class="mb-3 text-sm text-muted">
        {gettext(
          "Typed after the ticket command, like %{example}. Leave blank to turn one off.",
          example: "#{List.first(@commands, "!admin")} status"
        )}
      </p>
      <div class="grid gap-4 sm:grid-cols-2">
        <.input
          field={@form[:status_word]}
          type="text"
          label={gettext("Word to check the ticket")}
          placeholder="status"
          no_margin
        />
        <.input
          field={@form[:close_word]}
          type="text"
          label={gettext("Word to close the ticket")}
          placeholder="close"
          no_margin
        />
      </div>
    </div>
    """
  end

  defp section_body(%{name: :categories} = assigns) do
    ~H"""
    <p class="text-sm text-muted">
      {gettext(
        "The word right after the command picks the category, like %{example}. Each category opens tickets at its own priority.",
        example: "#{List.first(@commands, "!admin")} cheat"
      )}
    </p>

    <div id="category-rows" class="space-y-2">
      <input type="hidden" name="settings[category_rows][_][name]" value="" />
      <p
        :if={@category_rows == []}
        class="rounded-box border border-dashed border-base-300 p-4 text-center text-sm text-muted"
        id="no-categories"
      >
        {gettext("No category yet: every ticket opens at the default priority.")}
      </p>
      <div
        :for={{row, index} <- Enum.with_index(@category_rows)}
        id={"category-row-#{index}"}
        class="flex items-end gap-2"
      >
        <div class="flex-1">
          <.input
            name={"settings[category_rows][#{index}][name]"}
            id={"settings_category_rows_#{index}_name"}
            value={row["name"]}
            type="text"
            label={gettext("Category")}
            label_class={index > 0 && "sr-only"}
            placeholder="cheat"
            no_margin
          />
        </div>
        <div class="w-36">
          <.input
            name={"settings[category_rows][#{index}][priority]"}
            id={"settings_category_rows_#{index}_priority"}
            value={row["priority"]}
            type="select"
            options={Labels.ticket_priority_options()}
            label={gettext("Priority")}
            label_class={index > 0 && "sr-only"}
            no_margin
          />
        </div>
        <button
          type="button"
          phx-click="remove_category"
          phx-value-index={index}
          class="mb-1.5 cursor-pointer rounded-field p-1.5 text-muted hover:bg-base-200 hover:text-error"
          title={gettext("Remove")}
          aria-label={gettext("Remove")}
        >
          <.icon name="hero-trash" class="size-4" />
        </button>
      </div>
      <p
        :for={error <- @form[:category_priorities].errors}
        :if={@form.source.action}
        class="text-sm text-error"
      >
        {translate_error(error)}
      </p>
    </div>

    <div class="flex flex-wrap items-end justify-between gap-3">
      <.button
        type="button"
        size="xs"
        variant="outline"
        color="gray"
        icon="hero-plus"
        phx-click="add_category"
        label={gettext("Add a category")}
      />
      <div class="w-56">
        <.input
          field={@form[:default_priority]}
          type="select"
          options={Labels.ticket_priority_options()}
          label={gettext("Priority without a category")}
          no_margin
        />
      </div>
    </div>
    """
  end

  defp section_body(%{name: :messages} = assigns) do
    ~H"""
    <p class="text-sm text-muted">
      {gettext(
        "Leave a message blank to send nothing. {player} becomes the player's name and {command} the first command."
      )}
    </p>

    <div :for={
      {field, label, example} <- [
        {:received_message, gettext("When the ticket is opened"), nil},
        {:reply_prefix, gettext("Before each answer"), gettext("On my way")},
        {:closed_message, gettext("When the ticket is closed"), nil}
      ]
    }>
      <.input
        field={@form[field]}
        type={if field == :reply_prefix, do: "text", else: "textarea"}
        rows="2"
        label={label}
        help_text={
          field == :reply_prefix && gettext("{admin} becomes the name of the admin who answered.")
        }
      />
      <.game_message
        :if={present?(@form[field].value)}
        id={"preview-#{field}"}
        text={
          if example,
            do: sample(@form[field].value, @commands, @admin_name) <> " " <> example,
            else: sample(@form[field].value, @commands, @admin_name)
        }
      />
    </div>
    """
  end

  defp section_body(%{name: :replies} = assigns) do
    ~H"""
    <.input
      name="settings[quick_replies_text]"
      id="settings_quick_replies_text"
      value={@quick_replies_text}
      type="textarea"
      rows="6"
      label={gettext("One per line")}
      help_text={gettext("Shown as buttons on each ticket; a click fills the answer box.")}
    />
    """
  end

  defp section_body(%{name: :schedule} = assigns) do
    ~H"""
    <.input
      field={@form[:hours_enabled]}
      type="switch"
      label={gettext("Only promise an answer during office hours")}
    />
    <p class="text-sm text-muted">
      {gettext(
        "Off: every player gets the opening message at any hour. On: outside these hours they get the message below, and the ticket waits for an admin."
      )}
    </p>
    <div class="grid gap-4 sm:grid-cols-2">
      <.input field={@form[:hours_start]} type="time" label={gettext("From")} />
      <.input
        field={@form[:hours_end]}
        type="time"
        label={gettext("Until")}
        help_text={gettext("Earlier than the start means past midnight.")}
      />
    </div>
    <fieldset id="hours-days">
      <legend class="mb-1 text-sm font-medium">{gettext("Days")}</legend>
      <input type="hidden" name="settings[hours_days][]" value="" />
      <div class="flex flex-wrap gap-2">
        <label
          :for={{label, day} <- weekdays()}
          class="flex cursor-pointer items-center gap-1.5 rounded-full border border-base-300 px-2.5 py-1 text-sm has-[:checked]:border-primary/50 has-[:checked]:bg-primary/10"
        >
          <input
            type="checkbox"
            name="settings[hours_days][]"
            value={day}
            checked={day in @hours_days}
            class="pc-checkbox"
          />
          {label}
        </label>
      </div>
    </fieldset>
    <.input
      field={@form[:offline_message]}
      type="textarea"
      rows="2"
      label={gettext("Outside office hours, the player reads")}
    />
    <.game_message
      :if={present?(@form[:offline_message].value)}
      id="preview-offline_message"
      text={sample(@form[:offline_message].value, @commands, @admin_name)}
    />
    """
  end

  defp section_body(%{name: :limits} = assigns) do
    ~H"""
    <div class="grid gap-4 sm:grid-cols-2">
      <.input
        field={@form[:cooldown_seconds]}
        type="number"
        min="0"
        max="3600"
        label={gettext("Seconds between tickets")}
        help_text={gettext("How long a player waits before opening another ticket. 0 turns it off.")}
      />
      <.input
        field={@form[:max_per_hour]}
        type="number"
        min="0"
        max="60"
        label={gettext("Tickets per player per hour")}
        help_text={gettext("Stops a player who opens ticket after ticket. 0 means no limit.")}
      />
      <.input
        field={@form[:auto_close_hours]}
        type="number"
        min="0"
        max="168"
        label={gettext("Close after hours without activity")}
        help_text={gettext("0 keeps tickets open until an admin closes them.")}
      />
      <.input
        field={@form[:attention_minutes]}
        type="number"
        min="0"
        max="1440"
        label={gettext("Alert after minutes without an answer")}
        help_text={gettext("A ticket waiting longer shows as urgent in Attention. 0 turns it off.")}
      />
    </div>
    """
  end

  defp section_body(%{name: :discord} = assigns) do
    ~H"""
    <p
      :if={@webhooks == []}
      class="rounded-box border border-dashed border-base-300 p-4 text-sm text-muted"
    >
      {gettext("No webhook registered yet.")}
      <.link navigate={~p"/discord/new"} class="font-medium text-primary hover:underline">
        {gettext("Register one")}
      </.link>
    </p>
    <div class="grid gap-4 sm:grid-cols-2">
      <.input
        field={@form[:discord_webhook_id]}
        type="select"
        prompt={gettext("Do not announce")}
        options={Enum.map(@webhooks, &{&1.name, &1.id})}
        label={gettext("Announce new tickets on")}
        help_text={gettext("A webhook registered under Discord.")}
      />
      <.input
        field={@form[:discord_mention_role_ids]}
        type="text"
        label={gettext("Roles to mention")}
        placeholder="123456789012345678"
        help_text={gettext("Role ids, separated by commas. Leave blank to mention nobody.")}
      />
    </div>
    """
  end

  @doc """
  A line as it shows in the game's chat, for previews.
  """
  attr :id, :string, required: true
  attr :text, :string, required: true

  def game_message(assigns) do
    ~H"""
    <div id={@id} class="mt-2 flex items-start gap-2" data-preview>
      <span class="mt-1.5 shrink-0 text-xs uppercase tracking-wide text-muted">
        {gettext("In game")}
      </span>
      <p class="rounded-field bg-neutral-900/90 px-3 py-2 font-mono text-xs leading-relaxed text-amber-100 shadow-inner">
        {@text}
      </p>
    </div>
    """
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
