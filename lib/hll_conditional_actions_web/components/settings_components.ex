defmodule HllConditionalActionsWeb.SettingsComponents do
  @moduledoc """
  Pieces the Ajustes pages share: the hub's door rows, the small uppercase
  section labels, people's initials avatars, the design's switch, the
  segmented pill and the panel shell. Private to this area; the shared
  building blocks live in `HllConditionalActionsWeb.Ui`.
  """

  use Phoenix.Component

  import PetalComponents.Icon

  @doc """
  The small uppercase label that opens a panel ("PESSOAS", "ENGINE").
  """
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def section_label(assigns) do
    ~H"""
    <span class={["text-xs uppercase tracking-[0.06em] text-muted", @class]} {@rest}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  @doc """
  A door to another page: icon tile, title, one line of context, chevron.
  """
  attr :id, :string, required: true
  attr :navigate, :string, required: true
  attr :icon, :string, default: nil
  attr :tone, :string, default: "neutral", values: ~w(neutral primary engine allies warning)
  attr :title, :string, required: true
  attr :dashed, :boolean, default: false
  attr :class, :any, default: nil
  slot :lead, doc: "replaces the icon tile (an avatar, for instance)"
  slot :inner_block, required: true

  def hub_row(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={@navigate}
      class={[
        "group flex items-center gap-3.5 rounded-[1.125rem] px-4 py-3.5 transition-colors",
        if(@dashed,
          do: "border border-dashed border-line-raised hover:bg-secondary",
          else: "bg-secondary hover:bg-base-300/70"
        ),
        @class
      ]}
    >
      <%= if @lead != [] do %>
        {render_slot(@lead)}
      <% else %>
        <span class={[
          "flex size-10 shrink-0 items-center justify-center rounded-xl",
          tile_tone(@tone, @dashed)
        ]}>
          <.icon name={@icon} class="size-[1.125rem]" />
        </span>
      <% end %>
      <span class="flex min-w-0 flex-1 flex-col gap-0.5">
        <strong class="truncate text-[0.9375rem] font-semibold">{@title}</strong>
        <span class="text-[0.8125rem] leading-snug text-muted">{render_slot(@inner_block)}</span>
      </span>
      <.icon
        name="hero-chevron-right"
        class="size-4 shrink-0 text-muted transition-transform group-hover:translate-x-0.5"
      />
    </.link>
    """
  end

  defp tile_tone(_tone, true), do: "bg-secondary text-subtle"
  defp tile_tone("primary", _dashed), do: "bg-primary/12 text-primary"
  defp tile_tone("engine", _dashed), do: "bg-accent/13 text-accent"
  defp tile_tone("allies", _dashed), do: "bg-allies/14 text-allies"
  defp tile_tone("warning", _dashed), do: "bg-warning/13 text-warning"
  defp tile_tone(_neutral, _dashed), do: "bg-base-300 text-base-content"

  @doc """
  A person's initials in a round chip, tinted by who they are so the same
  person keeps the same colour on every page.
  """
  attr :user, :map, required: true
  attr :size, :string, default: "md", values: ~w(xs sm md lg)
  attr :class, :any, default: nil

  def person_avatar(assigns) do
    ~H"""
    <span
      class={[
        "flex shrink-0 items-center justify-center rounded-full font-bold",
        avatar_size(@size),
        avatar_tone(@user),
        @class
      ]}
      aria-hidden="true"
    >
      {initials(@user)}
    </span>
    """
  end

  defp avatar_size("xs"), do: "size-7 text-[0.625rem]"
  defp avatar_size("sm"), do: "size-9 text-xs"
  defp avatar_size("lg"), do: "size-16 text-xl"
  defp avatar_size(_md), do: "size-10 text-[0.8125rem]"

  @avatar_tones [
    "bg-avatar text-base-content",
    "bg-accent/20 text-accent",
    "bg-primary/14 text-primary",
    "bg-axis/18 text-axis",
    "bg-allies/18 text-allies",
    "bg-secondary text-subtle"
  ]

  @doc "The tint of a person's avatar."
  @spec avatar_tone(map()) :: String.t()
  def avatar_tone(%{id: id}) when is_integer(id),
    do: Enum.at(@avatar_tones, rem(id, length(@avatar_tones)))

  def avatar_tone(_user), do: hd(@avatar_tones)

  @doc """
  Up to two initials: of the name when there is one, else of the username.

      iex> HllConditionalActionsWeb.SettingsComponents.initials(%{name: "Ana Paula", username: "ana"})
      "AP"
      iex> HllConditionalActionsWeb.SettingsComponents.initials(%{name: nil, username: "bruno"})
      "BR"
  """
  @spec initials(map()) :: String.t()
  def initials(%{name: name}) when is_binary(name) and name != "" do
    case String.split(name, ~r/[\s()]+/u, trim: true) do
      [one] -> one |> String.slice(0, 2) |> String.upcase()
      [first, second | _rest] -> String.upcase(String.first(first) <> String.first(second))
      [] -> "?"
    end
  end

  def initials(%{username: username}) when is_binary(username),
    do: username |> String.slice(0, 2) |> String.upcase()

  def initials(_user), do: "?"

  @doc """
  A time of day as the boards write it, "21:30", in the browser's zone.
  The server renders UTC until the hook runs.
  """
  attr :id, :string, required: true
  attr :at, :any, required: true
  attr :class, :any, default: nil

  def clock(assigns) do
    assigns =
      assign(
        assigns,
        :utc,
        case assigns.at do
          %NaiveDateTime{} = at -> DateTime.from_naive!(at, "Etc/UTC")
          at -> at
        end
      )

    ~H"""
    <time
      :if={@utc}
      id={@id}
      datetime={DateTime.to_iso8601(@utc)}
      phx-hook=".SettingsClock"
      class={["tabular-nums", @class]}
    >{Calendar.strftime(@utc, "%H:%M")}</time>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".SettingsClock">
      export default {
        mounted() { this.render() },
        updated() { this.render() },
        render() {
          const date = new Date(this.el.getAttribute("datetime"))
          this.el.textContent = new Intl.DateTimeFormat(document.documentElement.lang || "en", {hour: "2-digit", minute: "2-digit", hour12: false}).format(date)
        }
      }
    </script>
    """
  end

  @doc """
  A centred dialog (the Servers board's "Adicionar servidor"): header with an
  icon tile, title and close button, a scrolling body and a footer bar.

  Rendered means open, like `Ui.modal/1`; closing (the X, Escape, the
  backdrop) runs `on_cancel`.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :icon, :string, default: nil
  attr :on_cancel, Phoenix.LiveView.JS, default: %Phoenix.LiveView.JS{}
  attr :class, :any, default: nil
  slot :inner_block, required: true
  slot :footer

  def settings_dialog(assigns) do
    ~H"""
    <dialog
      id={@id}
      class={["settings-dialog", @class]}
      phx-hook=".SettingsDialog"
      data-cancel={@on_cancel}
      aria-labelledby={"#{@id}-title"}
    >
      <div class="flex max-h-full min-h-0 flex-col">
        <div class="flex shrink-0 items-center gap-3.5 border-b border-line-soft px-5 py-[1.375rem] sm:px-7">
          <span
            :if={@icon}
            class="flex size-11 shrink-0 items-center justify-center rounded-[0.875rem] bg-primary/12 text-primary"
          >
            <.icon name={@icon} class="size-5" />
          </span>
          <span class="flex min-w-0 flex-1 flex-col gap-0.5">
            <h2 id={"#{@id}-title"} class="truncate font-display text-[1.375rem] font-semibold">
              {@title}
            </h2>
            <span :if={@subtitle} class="text-[0.8125rem] text-muted">{@subtitle}</span>
          </span>
          <form method="dialog">
            <button
              id={"#{@id}-close"}
              class="flex size-10 cursor-pointer items-center justify-center rounded-full border border-base-300 bg-secondary text-subtle transition-colors hover:text-base-content"
              aria-label={Gettext.gettext(HllConditionalActionsWeb.Gettext, "Close")}
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </form>
        </div>

        <div class="min-h-0 flex-1 overflow-y-auto px-5 py-6 sm:px-7">
          {render_slot(@inner_block)}
        </div>

        <div
          :if={@footer != []}
          class="flex shrink-0 flex-wrap items-center gap-3 border-t border-line-soft px-5 py-[1.125rem] sm:px-7"
        >
          {render_slot(@footer)}
        </div>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".SettingsDialog">
        export default {
          mounted() {
            this.el.showModal()
            this.el.addEventListener("mousedown", (e) => {
              if (e.target === this.el) this.el.close()
            })
            this.el.addEventListener("close", () => {
              const cancel = this.el.getAttribute("data-cancel")
              if (cancel && cancel !== "[]") this.liveSocket.execJS(this.el, cancel)
            })
          }
        }
      </script>
    </dialog>
    """
  end

  @doc """
  The design's switch around a real checkbox, so forms post exactly what a
  checkbox would. Pass `name`/`value`/`checked` like an input.
  """
  attr :id, :string, required: true
  attr :name, :string, default: nil
  attr :value, :string, default: "true"
  attr :checked, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :label, :string, default: nil, doc: "the accessible name"
  attr :size, :string, default: "md", values: ~w(md lg)
  attr :rest, :global

  def switch(assigns) do
    ~H"""
    <span class={["settings-switch", @size == "lg" && "settings-switch--lg"]}>
      <input
        type="checkbox"
        id={@id}
        name={@name}
        value={@value}
        checked={@checked}
        disabled={@disabled}
        role="switch"
        aria-label={@label}
        {@rest}
      />
      <span></span>
    </span>
    """
  end
end
