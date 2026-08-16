defmodule HllConditionalActionsWeb.CoreComponents do
  @moduledoc """
  The thin core layer over Petal Components.

  Petal owns the primitives (buttons, fields, badges, icons, alerts —
  imported app-wide in `HllConditionalActionsWeb.html_helpers/0`); this
  module keeps only what is ours: the flash pipeline, the `<.input>` bridge
  that adapts the app's historic form call-sites onto Petal's `<.field>`,
  the JS show/hide transitions, and gettext error translation.

  Application-level components (cards, stats, modals, tables…) live in
  `HllConditionalActionsWeb.Ui`.
  """
  use Phoenix.Component
  use Gettext, backend: HllConditionalActionsWeb.Gettext

  import PetalComponents.Icon

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class={[
        "pointer-events-auto flex w-full items-start gap-3 rounded-box border p-4 text-sm shadow-lg",
        @kind == :info && "border-info/30 bg-base-100 text-base-content",
        @kind == :error && "border-error/40 bg-base-100 text-base-content"
      ]}
      {@rest}
    >
      <.icon
        :if={@kind == :info}
        name="hero-information-circle"
        class="size-5 shrink-0 text-info"
      />
      <.icon
        :if={@kind == :error}
        name="hero-exclamation-circle"
        class="size-5 shrink-0 text-error"
      />
      <div class="min-w-0 flex-1">
        <p :if={@title} class="font-semibold">{@title}</p>

        <p>{msg}</p>
      </div>

      <button type="button" class="group cursor-pointer self-start" aria-label={gettext("close")}>
        <.icon name="hero-x-mark" class="size-5 opacity-40 group-hover:opacity-70" />
      </button>
    </div>
    """
  end

  @doc """
  The app's historic form input, bridged onto Petal's `<.field>`.

  Every template writes `<.input field={@form[:name]} type="select" …>`;
  this adapter keeps that call shape while Petal renders the control, the
  label, the help text and the (gettext-translated) errors.
  """
  attr :id, :any, default: nil
  attr :name, :any, default: nil
  attr :label, :string, default: nil
  attr :value, :any, default: nil

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select switch tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    default: nil,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, default: [], doc: "the options for select inputs"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "extra classes for the rendered control"
  attr :label_class, :any, default: nil, doc: "extra classes for the label (e.g. sr-only)"
  attr :no_margin, :boolean, default: false, doc: "drops the field's bottom margin"
  attr :help_text, :string, default: nil

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{type: "hidden"} = assigns) do
    assigns =
      with %{field: %Phoenix.HTML.FormField{} = field} <- assigns do
        assigns
        |> assign(:field, nil)
        |> assign_new(:name, fn -> field.name end)
        |> assign_new(:value, fn -> field.value end)
      end

    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{field: %Phoenix.HTML.FormField{}} = assigns) do
    ~H"""
    <PetalComponents.Field.field
      field={@field}
      id={@id}
      label={@label}
      label_class={@label_class}
      no_margin={@no_margin}
      type={@type}
      options={@options}
      prompt={@prompt}
      multiple={@multiple}
      class={@class}
      help_text={@help_text}
      {@rest}
    />
    """
  end

  def input(assigns) do
    ~H"""
    <PetalComponents.Field.field
      id={@id}
      name={@name}
      value={@value}
      label={@label}
      label_class={@label_class}
      no_margin={@no_margin}
      type={@type}
      options={@options}
      prompt={@prompt}
      multiple={@multiple}
      class={@class}
      help_text={@help_text}
      {@rest}
    />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(HllConditionalActionsWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(HllConditionalActionsWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
