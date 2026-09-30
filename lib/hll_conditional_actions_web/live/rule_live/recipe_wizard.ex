defmodule HllConditionalActionsWeb.RuleLive.RecipeWizard do
  @moduledoc """
  The short wizard `/rules/new?recipe=...` opens with, for recipes that
  declare questions (`HllConditionalActions.Rules.RecipeAnswers`) - the
  dialog of the Recipes board.

  Two or three numbered questions, then which servers get the rule; beside
  them the rule read back as the answers change, and what it would have done
  with the real events of the last week (`HllConditionalActions.Rules.Bench`).
  Two ways out: **create in simulation**, which saves one rule per chosen
  server as it stands (recipes always start in simulation), or **open in the
  builder**, which hands the answered recipe to the full form via
  `{:customize_recipe, attrs}` to the parent.
  """

  use HllConditionalActionsWeb, :live_component

  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Bench
  alias HllConditionalActions.Rules.RecipeAnswers
  alias HllConditionalActions.Rules.Rule

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    socket =
      socket
      |> assign(Map.take(assigns, [:id, :recipe, :attrs, :current_user, :servers]))
      |> assign_new(:servers, fn -> [] end)
      |> assign_new(:taken, fn -> taken(assigns) end)

    socket =
      if socket.assigns[:answers],
        do: socket,
        else:
          socket
          |> assign(:answers, RecipeAnswers.defaults(assigns.recipe, assigns.attrs))
          |> assign(:chosen, default_servers(socket))

    {:ok, socket |> assign_new(:error, fn -> nil end) |> assign_replay()}
  end

  # The server the page was opened for, else the first server of the
  # recipe's game that does not already run it. Every other one is a choice
  # the admin makes.
  defp default_servers(socket) do
    case socket.assigns.attrs[:server_id] || socket.assigns.attrs["server_id"] do
      nil ->
        socket.assigns
        |> game_servers()
        |> Enum.reject(&(&1.id in socket.assigns.taken))
        |> Enum.take(1)
        |> Enum.map(& &1.id)

      id ->
        [id]
    end
  end

  @impl Phoenix.LiveComponent
  def handle_event("change", params, socket) do
    defaults = RecipeAnswers.defaults(socket.assigns.recipe, socket.assigns.attrs)
    answers = RecipeAnswers.cast(socket.assigns.recipe, defaults, params["answers"] || %{})

    chosen =
      case params["servers"] do
        nil -> socket.assigns.chosen
        ids -> ids |> List.wrap() |> Enum.flat_map(&parse_id/1)
      end

    {:noreply, socket |> assign(answers: answers, chosen: chosen) |> assign_replay()}
  end

  def handle_event("step", %{"question" => id, "by" => by}, socket) do
    question = Enum.find(questions(socket), &(to_string(&1.id) == id))

    case {question, Integer.parse(by)} do
      {%{type: :integer} = question, {delta, ""}} ->
        value = (socket.assigns.answers[question.id] || 0) + delta
        value = value |> max(question[:min] || value) |> min(question[:max] || value)

        {:noreply,
         socket
         |> assign(:answers, Map.put(socket.assigns.answers, question.id, value))
         |> assign_replay()}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("create", params, socket) do
    {:noreply, socket} = handle_event("change", Map.put_new(params, "answers", %{}), socket)
    attrs = answered_attrs(socket)

    targets = socket.assigns.chosen

    results =
      Enum.map(targets, fn server_id ->
        attrs
        |> Map.put(:server_id, server_id)
        |> Rules.create_rule(actor: socket.assigns.current_user)
      end)

    case Enum.filter(results, &match?({:ok, _rule}, &1)) do
      [{:ok, rule}] ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Rule created in simulation. It records what it would do."))
         |> push_navigate(to: ~p"/rules/#{rule}")}

      [_first | _more] = created ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           ngettext(
             "1 rule created in simulation.",
             "%{count} rules created in simulation, one per server.",
             length(created)
           )
         )
         |> push_navigate(to: ~p"/rules")}

      [] when targets == [] ->
        {:noreply, assign(socket, :error, gettext("Pick at least one server."))}

      [] ->
        {:noreply,
         assign(socket, :error, gettext("This rule needs a closer look. Open it to customize."))}
    end
  end

  def handle_event("customize", _params, socket) do
    attrs =
      case socket.assigns.chosen do
        [id] -> Map.put(answered_attrs(socket), :server_id, id)
        _other -> answered_attrs(socket)
      end

    send(self(), {:customize_recipe, attrs})
    {:noreply, socket}
  end

  defp answered_attrs(socket) do
    RecipeAnswers.apply(socket.assigns.attrs, socket.assigns.recipe, socket.assigns.answers)
  end

  defp questions(socket), do: RecipeAnswers.questions(socket.assigns.recipe)

  # "Had it been running for the last week": the answered rule over the real
  # events of the chosen servers.
  defp assign_replay(socket) do
    servers = Enum.filter(game_servers(socket.assigns), &(&1.id in socket.assigns.chosen))
    changeset = Rules.change_rule(%Rule{}, answered_attrs(socket))
    rule = Ecto.Changeset.apply_changes(changeset)

    replay =
      if servers == [],
        do: nil,
        else: Bench.replay(rule, Bench.events(servers, rule.trigger_event))

    socket |> assign(:rule, rule) |> assign(:replay, replay)
  end

  defp game_servers(assigns) do
    game = assigns.attrs[:game] || assigns.attrs["game"] || :hll
    Enum.filter(assigns.servers || [], &(to_string(&1.game) == to_string(game)))
  end

  # Servers that already run a rule of this recipe's name.
  defp taken(assigns) do
    name = assigns.attrs[:name] || assigns.attrs["name"]

    Rules.list_rules()
    |> Enum.filter(&(&1.name == name and not is_nil(&1.server_id)))
    |> Enum.map(& &1.server_id)
  end

  defp parse_id(value) do
    case Integer.parse(to_string(value)) do
      {id, ""} -> [id]
      _other -> []
    end
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    assigns =
      assign(assigns,
        questions: RecipeAnswers.questions(assigns.recipe),
        servers_list: game_servers(assigns),
        message: message_of(assigns.rule)
      )

    ~H"""
    <div
      id={@id}
      role="dialog"
      aria-modal="true"
      aria-labelledby="wizard-title"
      class="mx-auto flex w-full max-w-[68.75rem] flex-col overflow-hidden rounded-[1.75rem] border border-base-300 bg-base-100 shadow-card-large"
    >
      <div class="flex flex-wrap items-center gap-4 border-b border-base-300 px-5 py-5 sm:px-7 sm:py-[1.375rem]">
        <span class="flex size-13 shrink-0 items-center justify-center rounded-2xl bg-accent/13 text-accent">
          <.recipe_art id={@recipe.id} class="size-8" />
        </span>
        <div class="flex min-w-0 flex-1 basis-60 flex-col gap-[0.1875rem]">
          <span class="text-[0.8125rem] text-muted">
            {ngettext("Recipe · 1 question", "Recipe · %{count} questions", length(@questions) + 1)}
          </span>
          <h2
            id="wizard-title"
            class="font-display text-[1.5rem] font-semibold tracking-tight sm:text-[1.625rem]"
          >
            {Labels.recipe_name(@recipe.id)}
          </h2>
        </div>
        <span class="flex h-7 items-center gap-1.5 rounded-full bg-accent/13 px-3 text-xs font-semibold text-accent">
          <span class="bench-dash-dot size-[0.4375rem]"></span>{gettext("Starts in simulation")}
        </span>
        <.link
          navigate={~p"/rules"}
          aria-label={gettext("Close")}
          class="flex size-11 shrink-0 items-center justify-center rounded-full border border-base-300 bg-secondary"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </.link>
      </div>

      <form
        id="recipe-wizard-form"
        phx-change="change"
        phx-submit="create"
        phx-target={@myself}
        class="flex flex-col"
      >
        <div class="grid lg:grid-cols-[minmax(0,1fr)_26.25rem]">
          <div class="flex flex-col gap-[1.375rem] px-5 py-6 sm:px-7">
            <fieldset
              :for={{question, index} <- Enum.with_index(@questions, 1)}
              class="grid grid-cols-[2rem_minmax(0,1fr)] gap-3.5"
            >
              <span class="flex size-8 items-center justify-center rounded-full bg-primary font-mono text-[0.8125rem] font-medium text-primary-content">
                {index}
              </span>
              <div class="flex min-w-0 flex-col gap-2.5">
                <legend class="text-base font-semibold">{question_label(question.id)}</legend>
                <span :if={question_hint(question.id)} class="-mt-1 text-[0.8125rem] text-muted">
                  {question_hint(question.id)}
                </span>

                <div
                  :if={question.type == :integer}
                  class="flex items-center gap-1 self-start rounded-2xl border border-base-300 bg-secondary p-1"
                >
                  <button
                    type="button"
                    phx-click="step"
                    phx-value-question={question.id}
                    phx-value-by="-1"
                    phx-target={@myself}
                    aria-label={gettext("Less")}
                    class="flex size-10 cursor-pointer items-center justify-center rounded-xl bg-base-100 text-lg"
                  >
                    −
                  </button>
                  <label class="flex items-baseline gap-1.5 px-3">
                    <span class="sr-only">{question_label(question.id)}</span>
                    <input
                      type="number"
                      inputmode="numeric"
                      name={"answers[#{question.id}]"}
                      value={@answers[question.id]}
                      min={question[:min]}
                      max={question[:max]}
                      class="w-14 border-0 bg-transparent p-0 text-center font-display text-xl font-semibold [appearance:textfield] focus:ring-0 focus:outline-none [&::-webkit-inner-spin-button]:appearance-none"
                    />
                    <span :if={question_unit(question.id)} class="text-[0.8125rem] text-muted">
                      {question_unit(question.id)}
                    </span>
                  </label>
                  <button
                    type="button"
                    phx-click="step"
                    phx-value-question={question.id}
                    phx-value-by="1"
                    phx-target={@myself}
                    aria-label={gettext("More")}
                    class="flex size-10 cursor-pointer items-center justify-center rounded-xl bg-base-100 text-lg"
                  >
                    +
                  </button>
                </div>

                <div
                  :if={question.type == :choice}
                  role="radiogroup"
                  aria-label={question_label(question.id)}
                  class="flex flex-wrap gap-1 self-start rounded-full border border-base-300 bg-secondary p-1"
                >
                  <label :for={option <- question.options} class="cursor-pointer">
                    <input
                      type="radio"
                      name={"answers[#{question.id}]"}
                      value={option}
                      checked={@answers[question.id] == option}
                      class="peer sr-only"
                    />
                    <span class="flex h-[2.375rem] items-center rounded-full px-4 text-[0.8125rem] text-subtle peer-checked:bg-base-content peer-checked:font-semibold peer-checked:text-base-100 peer-focus-visible:ring-2 peer-focus-visible:ring-primary">
                      {Labels.action(option)}
                    </span>
                  </label>
                </div>

                <textarea
                  :if={question.type == :text}
                  name={"answers[#{question.id}]"}
                  rows="2"
                  phx-debounce="300"
                  class="bench-tile h-auto py-2.5 leading-relaxed"
                >{@answers[question.id]}</textarea>
              </div>
            </fieldset>

            <fieldset class="grid grid-cols-[2rem_minmax(0,1fr)] gap-3.5">
              <span class="flex size-8 items-center justify-center rounded-full bg-primary font-mono text-[0.8125rem] font-medium text-primary-content">
                {length(@questions) + 1}
              </span>
              <div class="flex min-w-0 flex-col gap-2.5">
                <legend class="text-base font-semibold">{gettext("On which servers?")}</legend>
                <input type="hidden" name="servers[]" value="" />
                <div class="grid gap-2.5 sm:grid-cols-3">
                  <label
                    :for={server <- @servers_list}
                    class={[
                      "flex flex-col gap-1 rounded-2xl border px-3.5 py-3",
                      if(server.id in @chosen,
                        do: "border-primary/50 bg-primary/8",
                        else: "border-base-300 bg-secondary"
                      ),
                      server.id in @taken && "opacity-80"
                    ]}
                  >
                    <span class="flex items-center gap-2">
                      <input
                        type="checkbox"
                        name="servers[]"
                        value={server.id}
                        checked={server.id in @chosen}
                        disabled={server.id in @taken}
                        class="pc-checkbox"
                      />
                      <strong class={[
                        "truncate text-sm font-semibold",
                        server.id in @taken && "text-subtle"
                      ]}>
                        {server.name}
                      </strong>
                    </span>
                    <span
                      :if={server.id in @taken}
                      class="pl-[1.625rem] text-xs text-warning"
                    >
                      {gettext("already has this recipe")}
                    </span>
                  </label>
                </div>
              </div>
            </fieldset>
          </div>

          <aside
            aria-label={gettext("How the rule will look")}
            class="wizard-aside flex flex-col gap-3.5 border-t px-5 py-6 sm:px-[1.625rem] lg:border-t-0 lg:border-l"
          >
            <div class="flex items-baseline gap-3">
              <h3 class="flex-1 font-display text-lg font-semibold">
                {gettext("How the rule will look")}
              </h3>
              <span class="text-xs text-accent">{gettext("updates live")}</span>
            </div>
            <p id="recipe-wizard-sentence" class="text-base leading-[1.75] text-subtle">
              <span
                :for={{kind, text} <- sentence_parts(@recipe.id, @answers)}
                class={kind == :chip && "wizard-chip"}
              >{text}</span>
            </p>
            <div
              :if={@message}
              class="wizard-message rounded-[0.875rem] px-3.5 py-3 font-mono text-[0.8125rem] leading-relaxed"
            >
              {@message}
            </div>
            <div class="flex flex-wrap gap-1.5">
              <span
                :for={chip <- rule_chips(@rule)}
                class="wizard-chip rounded-full px-2.5 py-[0.3125rem] text-xs font-normal"
              >
                {chip}
              </span>
            </div>
            <div
              :if={@replay}
              id="recipe-wizard-replay"
              class="flex flex-col gap-1 border-t border-accent/25 pt-3.5"
            >
              <span class="text-xs text-accent">
                {gettext("Had it been running for the last %{count} days", count: Bench.days())}
              </span>
              <span class="text-sm">
                <strong class="font-display text-[1.375rem] font-semibold">{@replay.players}</strong>
                {ngettext(
                  "player reached in 1 run",
                  "players reached in %{count} runs",
                  @replay.fires
                )}
              </span>
            </div>
            <p
              :if={@error}
              class="flex items-start gap-2 rounded-2xl bg-warning/10 px-4 py-3 text-[0.8125rem] text-warning ring-1 ring-warning/35"
              role="alert"
            >
              <.icon name="hero-exclamation-triangle" class="mt-px size-4 shrink-0" />
              {@error}
            </p>
          </aside>
        </div>

        <div class="flex flex-wrap items-center gap-3 border-t border-base-300 px-5 py-[1.125rem] sm:px-7">
          <span class="min-w-0 flex-1 basis-60 text-[0.8125rem] text-muted">
            {gettext(
              "Once created, you follow the simulation on the rule's page and go live when you want."
            )}
          </span>
          <button
            type="button"
            phx-click="customize"
            phx-target={@myself}
            class="h-12 cursor-pointer rounded-full border border-base-300 bg-secondary px-5 text-sm font-medium"
          >
            {gettext("Open in the builder")}
          </button>
          <button
            type="submit"
            phx-disable-with={gettext("Creating...")}
            class="flex h-12 cursor-pointer items-center gap-2 rounded-full bg-primary pr-[1.375rem] pl-[1.125rem] text-sm font-semibold text-primary-content"
          >
            <.icon name="hero-beaker" class="size-4" />{gettext("Create in simulation")}
          </button>
        </div>
      </form>
    </div>
    """
  end

  defp message_of(%Rule{actions: actions}) do
    Enum.find_value(actions || [], fn action ->
      case (action.parameters || %{})["message"] do
        text when is_binary(text) and text != "" -> text
        _none -> nil
      end
    end)
  end

  # The rule's limits and folder, as the aside's chips.
  defp rule_chips(rule) do
    [
      (rule.max_executions_per_player || 0) > 0 &&
        ngettext(
          "once per player in 24 h",
          "%{count} times per player in 24 h",
          rule.max_executions_per_player
        ),
      (rule.cooldown_seconds || 0) > 0 &&
        gettext("waits %{gap} between runs",
          gap: HllConditionalActionsWeb.RuleLive.Form.format_duration(rule.cooldown_seconds)
        ),
      (rule.escalation_window_seconds || 0) > 0 &&
        ngettext("1 step", "a ladder of %{count} steps", length(rule.actions)),
      rule.group && gettext("group %{group}", group: rule.group)
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp question_label(:message), do: gettext("Message the player reads")

  defp question_label(:limit),
    do: gettext("On which team kill does the final punishment come?")

  defp question_label(:final_action), do: gettext("Final punishment")
  defp question_label(:min_players), do: gettext("Only when at least this many players are on")
  defp question_label(:max_players), do: gettext("Seeding means at most this many players")
  defp question_label(:vip_hours), do: gettext("Hours of VIP granted")
  defp question_label(id), do: to_string(id)

  defp question_hint(:max_players),
    do: gettext("While the server has fewer than this, the rule counts who is playing.")

  defp question_hint(_id), do: nil

  defp question_unit(id) when id in [:min_players, :max_players], do: gettext("players")
  defp question_unit(:vip_hours), do: gettext("hours")
  defp question_unit(:limit), do: gettext("team kills")
  defp question_unit(_id), do: nil

  @doc "The rule the answers describe, in one sentence."
  @spec sentence(atom(), map()) :: String.t()
  def sentence(:welcome, answers),
    do: gettext("When a player connects, they read: “%{message}”.", message: answers[:message])

  def sentence(:chat_command_discord, answers),
    do:
      gettext("When a player types !discord in chat, they are answered: “%{message}”.",
        message: answers[:message]
      )

  def sentence(:team_kill_ladder, answers),
    do:
      gettext(
        "Each team kill within an hour moves the player one step up a ladder: first a warning (“%{message}”), punishments in between, and on team kill number %{limit}: %{final}.",
        message: answers[:message],
        limit: answers[:limit],
        final: final(answers)
      )

  def sentence(:no_squad_leader, answers),
    do:
      gettext(
        "With at least %{players} players on, a squad of three or more without an officer is warned twice and then: %{final}.",
        players: answers[:min_players],
        final: final(answers)
      )

  def sentence(:solo_tank, answers),
    do:
      gettext(
        "With at least %{players} players on, someone alone in an armor squad is warned and then: %{final}.",
        players: answers[:min_players],
        final: final(answers)
      )

  def sentence(:seeding_reward, answers),
    do:
      gettext(
        "While the server has %{players} players or fewer, anyone who has played 30 minutes gets VIP for %{hours} hours.",
        players: answers[:max_players],
        hours: answers[:vip_hours]
      )

  def sentence(recipe_id, _answers), do: Labels.recipe_description(recipe_id)

  defp final(answers) do
    case answers[:final_action] do
      nil -> "-"
      type -> type |> Labels.action() |> String.downcase() |> mark(answers)
    end
  end

  @open "\u0001"
  @close "\u0002"

  # The sentence with the answers as chips, the way the board reads it back:
  # each answer is wrapped in markers before the sentence is built, then the
  # sentence is cut at them.
  defp sentence_parts(recipe_id, answers) do
    marked =
      answers
      |> Map.new(fn
        {key, value} when is_integer(value) -> {key, @open <> to_string(value) <> @close}
        pair -> pair
      end)
      |> Map.put(:__mark__, true)

    recipe_id
    |> sentence(marked)
    |> String.split(@open)
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {text, 0} ->
        [{:text, text}]

      {part, _index} ->
        case String.split(part, @close, parts: 2) do
          [chip, rest] -> [{:chip, chip}, {:text, rest}]
          [text] -> [{:text, text}]
        end
    end)
    |> Enum.reject(fn {_kind, text} -> text == "" end)
  end

  defp mark(text, %{__mark__: true}), do: @open <> text <> @close
  defp mark(text, _answers), do: text
end
