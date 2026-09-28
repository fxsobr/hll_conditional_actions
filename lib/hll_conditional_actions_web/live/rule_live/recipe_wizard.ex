defmodule HllConditionalActionsWeb.RuleLive.RecipeWizard do
  @moduledoc """
  The short wizard `/rules/new?recipe=...` opens with, for recipes that
  declare questions (`HllConditionalActions.Rules.RecipeAnswers`).

  Two or three questions, a sentence that reads the rule back as the
  answers change, and two ways out: **create in simulation**, which saves
  the rule as it stands (recipes always start in simulation), or
  **customize**, which hands the answered recipe to the full builder via
  `{:customize_recipe, attrs}` to the parent.
  """

  use HllConditionalActionsWeb, :live_component

  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.RecipeAnswers

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    socket = assign(socket, Map.take(assigns, [:id, :recipe, :attrs, :current_user]))

    socket =
      if socket.assigns[:answers],
        do: socket,
        else: assign(socket, :answers, RecipeAnswers.defaults(assigns.recipe, assigns.attrs))

    {:ok, assign_new(socket, :error, fn -> nil end)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("change", %{"answers" => params}, socket) do
    defaults = RecipeAnswers.defaults(socket.assigns.recipe, socket.assigns.attrs)

    {:noreply,
     assign(socket, :answers, RecipeAnswers.cast(socket.assigns.recipe, defaults, params))}
  end

  def handle_event("create", params, socket) do
    {:noreply, socket} = handle_event("change", Map.put_new(params, "answers", %{}), socket)

    case Rules.create_rule(answered_attrs(socket), actor: socket.assigns.current_user) do
      {:ok, rule} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Rule created in simulation. It records what it would do."))
         |> push_navigate(to: ~p"/rules/#{rule}")}

      {:error, _changeset} ->
        {:noreply,
         assign(socket, :error, gettext("This rule needs a closer look. Open it to customize."))}
    end
  end

  def handle_event("customize", _params, socket) do
    send(self(), {:customize_recipe, answered_attrs(socket)})
    {:noreply, socket}
  end

  defp answered_attrs(socket) do
    RecipeAnswers.apply(socket.assigns.attrs, socket.assigns.recipe, socket.assigns.answers)
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id={@id} class="mx-auto max-w-xl space-y-6">
      <div class="flex items-center gap-3">
        <.recipe_art id={@recipe.id} class="size-12 shrink-0" />
        <div>
          <h1 class="text-xl font-semibold">{Labels.recipe_name(@recipe.id)}</h1>
          <p class="text-sm text-subtle">{Labels.recipe_description(@recipe.id)}</p>
        </div>
      </div>

      <.card>
        <form
          id="recipe-wizard-form"
          phx-change="change"
          phx-submit="create"
          phx-target={@myself}
          class="space-y-4"
        >
          <label :for={question <- RecipeAnswers.questions(@recipe)} class="block space-y-1">
            <span class="text-sm font-medium">{question_label(question.id)}</span>
            <input
              :if={question.type == :integer}
              type="number"
              name={"answers[#{question.id}]"}
              value={@answers[question.id]}
              min={question[:min]}
              max={question[:max]}
              class="pc-text-input w-full"
            />
            <select
              :if={question.type == :choice}
              name={"answers[#{question.id}]"}
              class="pc-text-input w-full"
            >
              <option
                :for={option <- question.options}
                value={option}
                selected={@answers[question.id] == option}
              >
                {Labels.action(option)}
              </option>
            </select>
            <textarea
              :if={question.type == :text}
              name={"answers[#{question.id}]"}
              rows="2"
              phx-debounce="300"
              class="pc-text-input w-full"
            >{@answers[question.id]}</textarea>
          </label>

          <div
            class="rounded-box bg-primary/5 p-3 text-sm ring-1 ring-primary/15"
            id="recipe-wizard-sentence"
          >
            <p class="mb-1 text-xs font-medium text-subtle">{gettext("In one sentence")}</p>
            <p>{sentence(@recipe.id, @answers)}</p>
          </div>

          <.alert :if={@error} color="warning" variant="soft" with_icon label={@error} />

          <div class="flex flex-wrap gap-2">
            <.button
              type="submit"
              icon="hero-beaker"
              label={gettext("Create in simulation")}
              phx-disable-with={gettext("Creating...")}
            />
            <.button
              type="button"
              variant="outline"
              color="gray"
              icon="hero-adjustments-horizontal"
              phx-click="customize"
              phx-target={@myself}
              label={gettext("Customize")}
            />
          </div>
          <p class="text-xs text-muted">
            {gettext(
              "Simulation records what the rule would do without touching the game. Turn it off once the history looks right."
            )}
          </p>
        </form>
      </.card>
    </div>
    """
  end

  defp question_label(:message), do: gettext("Message the player reads")

  defp question_label(:limit),
    do: gettext("On which team kill does the final punishment come?")

  defp question_label(:final_action), do: gettext("Final punishment")
  defp question_label(:min_players), do: gettext("Only when at least this many players are on")
  defp question_label(:max_players), do: gettext("Seeding means at most this many players")
  defp question_label(:vip_hours), do: gettext("Hours of VIP granted")
  defp question_label(id), do: to_string(id)

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
      type -> type |> Labels.action() |> String.downcase()
    end
  end
end
