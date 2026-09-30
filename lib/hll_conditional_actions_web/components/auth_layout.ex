defmodule HllConditionalActionsWeb.AuthLayout do
  @moduledoc """
  The shell and the pieces of the sign in pages: entering (password, then
  the authenticator code), choosing a password of your own, and "Esqueci a
  senha".

  `shell/1` is two rounded panels on the ground colour: one of the game's
  maps full bleed on the left, with the name of the tool, a headline and a
  caption saying which map it is; the form on the right, with the language
  switch, the page's own control at the top (a "Voltar" pill, who is signing
  in) and a footer with the version. On a phone the map shrinks to a card
  above the form and the language switch moves to the bottom.

  The rest are the controls every one of those pages shares: `stepper/1`,
  `note/1`, `password_input/1` (with its show/hide eye),
  `new_password_fields/1` (strength meter and the `PasswordPolicy`
  checklist, ticked as you type), `code_boxes/1` (six digit boxes that
  advance, go back and take a pasted code) and the two countdowns.

  Several of these pages are plain controller pages; LiveView runs their
  hooks and JS commands all the same.
  """

  use HllConditionalActionsWeb, :html

  alias HllConditionalActions.Accounts.PasswordPolicy
  alias HllConditionalActions.Updates
  alias HllConditionalActionsWeb.MapArt
  alias HllConditionalActionsWeb.Plugs.Locale
  alias Phoenix.LiveView.JS

  # The map behind each page, as on the boards.
  @arts %{
    login: {"hill400-dusk.webp", "Hill 400", :dusk},
    code: {"carentan-dusk.webp", "Carentan", :dusk},
    password: {"foy-day.webp", "Foy", :day},
    reset: {"elalamein-day.webp", "El Alamein", :day}
  }

  # The order of the pills, whatever order Gettext lists its locales in.
  @locale_order ~w(pt_BR en es)

  # ── Shell ─────────────────────────────────────────────────────────────────

  @doc """
  The two panels around a sign in page.

  `art` picks the map (and the default headline): `:login`, `:code`,
  `:password` or `:reset`. `width={:wide}` lets the content take the whole
  panel instead of the 420px column.
  """
  attr :flash, :map, default: %{}
  attr :art, :atom, default: :login, values: [:login, :code, :password, :reset]
  attr :return_to, :string, default: "/login", doc: "where the language switch comes back to"
  attr :headline, :string, default: nil
  attr :lede, :string, default: nil
  attr :lede_short, :string, default: nil, doc: "the lede on a phone"
  attr :width, :atom, default: :narrow, values: [:narrow, :wide]
  slot :top, doc: "the control at the top left of the form panel"
  slot :inner_block, required: true

  def shell(assigns) do
    {file, map, time} = Map.fetch!(@arts, assigns.art)
    {headline, lede, lede_short} = hero(assigns.art)

    assigns =
      assigns
      |> assign(:image, MapArt.url(:hll, %{"image_name" => file}))
      |> assign(:caption, caption(map, time))
      |> assign(:alt, alt(map, time))
      |> assign(:headline, assigns.headline || headline)
      |> assign(:lede, assigns.lede || lede)
      |> assign(:lede_short, assigns.lede_short || lede_short || assigns.lede || lede)
      |> assign(:locale, Gettext.get_locale(HllConditionalActionsWeb.Gettext))
      |> assign(:version, version())

    ~H"""
    <div id="auth-frame" class="auth-frame">
      <section class="auth-art" aria-label={@alt}>
        <img src={@image} alt={@alt} class="auth-art-img" />
        <div class="auth-art-scrim" aria-hidden="true"></div>
        <div class="auth-art-body">
          <div class="auth-brand">
            <span class="auth-logo" aria-hidden="true">
              <svg
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="2.4"
                stroke-linecap="round"
                stroke-linejoin="round"
              >
                <path d="m5 11 7-5 7 5" /><path d="m5 17 7-5 7 5" />
              </svg>
            </span>
            <span class="flex flex-col">
              <strong class="auth-brand-name">{gettext("Conditional Actions")}</strong>
              <span class="auth-brand-sub">{gettext("for Hell Let Loose")}</span>
            </span>
          </div>
          <span class="grow" aria-hidden="true"></span>
          <p class="auth-headline">{@headline}</p>
          <p class="auth-lede auth-lede--long">{@lede}</p>
          <p class="auth-lede auth-lede--short">{@lede_short}</p>
          <span class="auth-caption">{@caption}</span>
        </div>
      </section>

      <section class="auth-panel">
        <div class={["auth-top", @top == [] && "auth-top--empty"]}>
          <div class="auth-top-left">{render_slot(@top)}</div>
          <.language_switch
            id="auth-lang"
            locale={@locale}
            return_to={@return_to}
            class="auth-lang--top"
          />
        </div>

        <span class="auth-spacer" aria-hidden="true"></span>
        <main class={["auth-column", @width == :wide && "auth-column--wide"]}>
          {render_slot(@inner_block)}
        </main>
        <span class="auth-spacer" aria-hidden="true"></span>

        <footer class="auth-foot">
          <span>{gettext("Talks to CRCON through its official API")}</span>
          <span class="font-mono">{@version}</span>
        </footer>
        <footer class="auth-foot-phone">
          <.language_switch id="auth-lang-phone" locale={@locale} return_to={@return_to} />
          <span class="font-mono">{@version}</span>
        </footer>
      </section>

      <div id="auth-flash" class="toast-stack" aria-live="polite">
        <.flash kind={:info} flash={@flash} />
        <.flash kind={:error} flash={@flash} />
      </div>
    </div>
    """
  end

  defp hero(art) when art in [:login, :code] do
    {gettext("Your server, on autopilot."),
     gettext(
       "Rules that act on their own, tickets that arrive from the chat and the live score of all your servers."
     ), gettext("Rules that act on their own, tickets from the chat and the live score.")}
  end

  defp hero(:password) do
    {gettext("First, a password of your own."),
     gettext("Pick something only you know. Then this account is yours alone."), nil}
  end

  defp hero(:reset) do
    {gettext("It happens to everybody."),
     gettext(
       "A link in your e-mail and you are back at your post. The authenticator app code is still asked for when you sign in."
     ), nil}
  end

  defp caption(map, :dusk), do: gettext("%{map} · dusk", map: map)
  defp caption(map, :day), do: gettext("%{map} · day", map: map)

  defp alt(map, :dusk), do: gettext("%{map} at dusk", map: map)
  defp alt(map, :day), do: gettext("%{map} during the day", map: map)

  # `mix.exs` says "0.3.0"; a Docker build stamps "v0.3.0-3-gabc123".
  defp version do
    case Updates.current_version() do
      "v" <> _rest = version -> version
      version -> "v" <> to_string(version)
    end
  end

  attr :id, :string, required: true
  attr :locale, :string, required: true
  attr :return_to, :string, required: true
  attr :class, :string, default: nil

  defp language_switch(assigns) do
    supported = Locale.supported()
    locales = Enum.filter(@locale_order, &(&1 in supported))
    assigns = assign(assigns, :locales, locales)

    ~H"""
    <nav
      :if={length(@locales) > 1}
      id={@id}
      class={["auth-lang", @class]}
      aria-label={gettext("Language")}
    >
      <.link
        :for={locale <- @locales}
        href={~p"/locale/#{locale}?#{[return_to: @return_to]}"}
        class="auth-lang-item"
        aria-current={if locale == @locale, do: "true"}
        lang={String.replace(locale, "_", "-")}
        title={locale_name(locale)}
      >
        {locale_short(locale)}
      </.link>
    </nav>
    """
  end

  defp locale_short("pt_BR"), do: "PT"
  defp locale_short(locale), do: locale |> String.slice(0, 2) |> String.upcase()

  defp locale_name("pt_BR"), do: "Português"
  defp locale_name("en"), do: "English"
  defp locale_name("es"), do: "Español"
  defp locale_name(locale), do: locale

  # ── Pieces ────────────────────────────────────────────────────────────────

  @doc """
  The steps of signing in, e.g. `[{"Senha", :current}, {"Código", :todo}]`.
  """
  attr :steps, :list, required: true
  attr :id, :string, default: nil

  def stepper(assigns) do
    assigns = assign(assigns, :indexed, Enum.with_index(assigns.steps, 1))

    ~H"""
    <ol id={@id} class="auth-stepper" aria-label={gettext("Steps")}>
      <%= for {{label, state}, n} <- @indexed do %>
        <li
          :if={n > 1}
          class={["auth-step-line", state != :todo && "auth-step-line--on"]}
          aria-hidden="true"
        >
        </li>
        <li
          class={["auth-step", "auth-step--#{state}"]}
          aria-current={if state == :current, do: "step"}
        >
          <span class="auth-step-dot">
            <%= if state == :done do %>
              <svg
                viewBox="0 0 24 24"
                class="size-[0.6875rem]"
                fill="none"
                stroke="currentColor"
                stroke-width="3.2"
                stroke-linecap="round"
                stroke-linejoin="round"
                aria-hidden="true"
              >
                <path d="m5 12.5 4.5 4.5L19 7.5" />
              </svg>
              <span class="sr-only">{gettext("(done)")}</span>
            <% else %>
              {n}
            <% end %>
          </span>
          {label}
        </li>
      <% end %>
    </ol>
    """
  end

  @doc "A quiet box with an icon: `:shield`, `:phone`, `:warning`, `:error` or `:mail`."
  attr :icon, :atom, default: :shield
  attr :tone, :atom, default: :neutral, values: [:neutral, :warning, :error]
  attr :id, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def note(assigns) do
    ~H"""
    <div id={@id} class={["auth-note", "auth-note--#{@tone}"]} {@rest}>
      <.glyph name={@icon} class="auth-note-icon" />
      <span>{render_slot(@inner_block)}</span>
    </div>
    """
  end

  @doc "The round pill at the top of the panel: a link back, or who is signing in."
  attr :href, :string, default: nil
  attr :id, :string, default: nil
  slot :inner_block, required: true

  def top_pill(assigns) do
    ~H"""
    <.link :if={@href} id={@id} href={@href} class="auth-pill auth-pill--back">
      <svg
        viewBox="0 0 24 24"
        class="size-4"
        fill="none"
        stroke="currentColor"
        stroke-width="2"
        stroke-linecap="round"
        stroke-linejoin="round"
        aria-hidden="true"
      >
        <path d="m15 18-6-6 6-6" />
      </svg>
      {render_slot(@inner_block)}
    </.link>
    <span :if={!@href} id={@id} class="auth-pill">{render_slot(@inner_block)}</span>
    """
  end

  @doc "The arrow at the end of a primary button."
  attr :class, :string, default: "size-[1.125rem]"

  def arrow(assigns) do
    ~H"""
    <svg
      viewBox="0 0 24 24"
      class={@class}
      fill="none"
      stroke="currentColor"
      stroke-width="2.2"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <path d="M5 12h14M13 6l6 6-6 6" />
    </svg>
    """
  end

  @doc """
  A password box with an eye that shows what was typed.

  The eye is a checkbox rather than a button: a form's buttons are its
  submit buttons, and the sign in form's first button must stay "Continuar".
  """
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :string, default: nil
  attr :autocomplete, :string, default: "current-password"
  attr :rest, :global, include: ~w(required autofocus aria-describedby aria-invalid)
  slot :trailing

  def password_input(assigns) do
    ~H"""
    <span class="auth-field auth-field--with-button">
      <input
        type="password"
        id={@id}
        name={@name}
        value={@value}
        autocomplete={@autocomplete}
        spellcheck="false"
        {@rest}
      />
      {render_slot(@trailing)}
      <label id={"#{@id}-eye"} class="auth-eye" title={gettext("Show password")} phx-update="ignore">
        <input
          type="checkbox"
          class="auth-eye-input"
          aria-label={gettext("Show password")}
          aria-controls={@id}
          phx-click={JS.toggle_attribute({"type", "text", "password"}, to: "##{@id}")}
        />
        <svg
          class="auth-eye-show"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="1.8"
          stroke-linecap="round"
          stroke-linejoin="round"
          aria-hidden="true"
        >
          <path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z" />
          <circle cx="12" cy="12" r="2.5" />
        </svg>
        <svg
          class="auth-eye-hide"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="1.8"
          stroke-linecap="round"
          stroke-linejoin="round"
          aria-hidden="true"
        >
          <path d="M3 3l18 18" />
          <path d="M10.6 5.6A10 10 0 0 1 12 5.5c6 0 9.5 6.5 9.5 6.5a17 17 0 0 1-2.7 3.4M6.6 6.7C3.9 8.4 2.5 12 2.5 12S6 18.5 12 18.5a9 9 0 0 0 4.3-1.1" />
          <path d="M9.9 10a2.5 2.5 0 0 0 3.6 3.5" />
        </svg>
      </label>
    </span>
    """
  end

  @doc """
  "Nova senha" and "Repita a nova senha", the strength meter and the
  policy's checklist, from what has been typed so far.

  `name` is the form's param name; the inputs are `name[password]` and
  `name[password_confirmation]`.
  """
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :typed, :map, default: %{}
  attr :username, :string, default: nil
  attr :errors, :list, default: [], doc: "messages about the password, already translated"
  attr :echo, :boolean, default: true, doc: "render what was typed back into the boxes"

  def new_password_fields(assigns) do
    password = to_string(assigns.typed["password"] || "")
    confirmation = to_string(assigns.typed["password_confirmation"] || "")
    checks = PasswordPolicy.checks(password, confirmation, assigns.username)
    strength = PasswordPolicy.strength(password, assigns.username)

    assigns =
      assign(assigns,
        password: password,
        confirmation: confirmation,
        checks: checks,
        strength: strength,
        hint: strength_hint(strength, checks, password),
        length: String.length(password),
        min: PasswordPolicy.min_length()
      )

    ~H"""
    <div class="flex flex-col gap-4">
      <div class="auth-group">
        <label class="auth-label" for={"#{@id}-password"}>{gettext("New password")}</label>
        <.password_input
          id={"#{@id}-password"}
          name={"#{@name}[password]"}
          value={if(@echo, do: @password)}
          autocomplete="new-password"
          aria-describedby={"#{@id}-strength #{@id}-rules"}
          aria-invalid={if(@errors != [], do: "true")}
          required
        />
      </div>

      <div id={"#{@id}-strength"} class="auth-strength">
        <div class={["auth-meter", "auth-meter--#{@strength}"]} aria-hidden="true">
          <span :for={n <- 1..4} class={["auth-meter-bar", n <= @strength && "is-on"]}></span>
        </div>
        <span class="flex justify-between gap-3 text-xs">
          <span class={["auth-strength-label", "auth-strength-label--#{@strength}"]}>
            {strength_label(@strength)}
          </span>
          <span :if={@hint} class="text-muted">{@hint}</span>
        </span>
      </div>

      <p :for={error <- @errors} class="auth-error-text" role="alert">{error}</p>

      <div class="auth-group">
        <label class="auth-label" for={"#{@id}-confirmation"}>{gettext("Repeat the new password")}</label>
        <span class="auth-field auth-field--with-icon">
          <input
            type="password"
            id={"#{@id}-confirmation"}
            name={"#{@name}[password_confirmation]"}
            value={if(@echo, do: @confirmation)}
            autocomplete="new-password"
            spellcheck="false"
            required
          />
          <svg
            :if={@checks[:match]}
            viewBox="0 0 24 24"
            class="auth-match"
            fill="none"
            stroke="currentColor"
            stroke-width="2.6"
            stroke-linecap="round"
            stroke-linejoin="round"
            role="img"
            aria-label={gettext("The passwords match")}
          >
            <path d="m5 12.5 4.5 4.5L19 7.5" />
          </svg>
        </span>
      </div>

      <ul id={"#{@id}-rules"} class="auth-rules">
        <.rule ok={@checks[:length]}>
          <span class="grow">{gettext("%{count} characters or more", count: @min)}</span>
          <span :if={@length > 0} class="font-mono text-xs text-muted">{@length}</span>
        </.rule>
        <.rule ok={@checks[:not_common]}>
          <span class="grow">
            <.around
              text={gettext("Not %{word} nor your username", word: hole())}
              class="font-mono"
              value="admin"
            />
          </span>
        </.rule>
        <.rule ok={@checks[:letters_and_digits]}>
          <span class="grow">{gettext("Letters and numbers")}</span>
        </.rule>
        <.rule ok={@checks[:symbol]}>
          <span class="grow">{gettext("A symbol")}</span>
          <span class="text-xs text-muted">{gettext("optional")}</span>
        </.rule>
        <.rule ok={@checks[:match]}>
          <span class="grow">{gettext("Both passwords match")}</span>
        </.rule>
      </ul>
    </div>
    """
  end

  attr :ok, :boolean, default: false
  slot :inner_block, required: true

  defp rule(assigns) do
    ~H"""
    <li class={["auth-rule", !@ok && "auth-rule--todo"]}>
      <svg
        :if={@ok}
        viewBox="0 0 24 24"
        class="auth-rule-mark"
        fill="none"
        stroke="currentColor"
        stroke-width="3"
        stroke-linecap="round"
        stroke-linejoin="round"
        aria-hidden="true"
      >
        <path d="m5 12.5 4.5 4.5L19 7.5" />
      </svg>
      <span :if={!@ok} class="auth-rule-ring" aria-hidden="true"></span>
      {render_slot(@inner_block)}
      <span class="sr-only">{if @ok, do: gettext("(done)"), else: gettext("(not yet)")}</span>
    </li>
    """
  end

  defp strength_label(0), do: ""
  defp strength_label(1), do: gettext("Weak")
  defp strength_label(2), do: gettext("Fair")
  defp strength_label(3), do: gettext("Good")
  defp strength_label(4), do: gettext("Strong")

  # What would light the last bar, when one bar is all that is missing.
  defp strength_hint(3, checks, password) do
    cond do
      not checks[:symbol] -> gettext("a symbol makes it strong")
      String.length(password) < 16 -> gettext("16 characters make it strong")
      true -> gettext("letters and numbers make it strong")
    end
  end

  defp strength_hint(_strength, _checks, _password), do: nil

  @doc """
  Six boxes for a six digit code, filling the hidden input `name`.

  Typing advances, Backspace goes back, arrows move, and a pasted (or
  autofilled) code spreads across the boxes. With `autosubmit` the form is
  sent once the sixth digit is in.
  """
  attr :id, :string, required: true
  attr :name, :string, default: "code"
  attr :input_id, :string, default: nil
  attr :autosubmit, :boolean, default: false
  attr :invalid, :boolean, default: false

  def code_boxes(assigns) do
    assigns = assign(assigns, :input_id, assigns.input_id || "#{assigns.id}-value")

    ~H"""
    <fieldset
      id={@id}
      class={["auth-code", @invalid && "auth-code--invalid"]}
      phx-hook=".CodeBoxes"
      phx-update="ignore"
      data-autosubmit={@autosubmit && "true"}
    >
      <legend class="sr-only">{gettext("6-digit code")}</legend>
      <input type="hidden" id={@input_id} name={@name} value="" data-code-value />
      <input
        :for={n <- 1..6}
        id={"#{@id}-#{n}"}
        type="text"
        class="auth-digit"
        inputmode="numeric"
        pattern="[0-9]*"
        autocomplete={if n == 1, do: "one-time-code", else: "off"}
        aria-label={gettext("Digit %{n}", n: n)}
        data-digit
      />
    </fieldset>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".CodeBoxes">
      export default {
        mounted() {
          this.boxes = Array.from(this.el.querySelectorAll("[data-digit]"))
          this.target = this.el.querySelector("[data-code-value]")
          const form = this.el.closest("form")
          const sync = () => {
            const code = this.boxes.map((b) => b.value).join("")
            this.target.value = code
            this.boxes.forEach((b) => b.classList.toggle("is-filled", b.value !== ""))
            return code
          }
          const fill = (start, text) => {
            const digits = (text || "").replace(/\D/g, "").split("")
            let i = start
            for (const d of digits) {
              if (i >= this.boxes.length) break
              this.boxes[i].value = d
              i++
            }
            const code = sync()
            const next = this.boxes[Math.min(i, this.boxes.length - 1)]
            next.focus()
            if (code.length === this.boxes.length && this.el.dataset.autosubmit && form && !this.sent) {
              this.sent = true
              form.requestSubmit()
            }
          }
          this.boxes.forEach((box, i) => {
            box.addEventListener("input", () => {
              const typed = box.value
              box.value = ""
              if (typed.replace(/\D/g, "") === "") { sync(); return }
              fill(i, typed)
            })
            box.addEventListener("keydown", (e) => {
              if (e.key === "Backspace" && box.value === "" && i > 0) {
                e.preventDefault()
                this.boxes[i - 1].value = ""
                this.boxes[i - 1].focus()
                sync()
              } else if (e.key === "ArrowLeft" && i > 0) {
                e.preventDefault()
                this.boxes[i - 1].focus()
              } else if (e.key === "ArrowRight" && i < this.boxes.length - 1) {
                e.preventDefault()
                this.boxes[i + 1].focus()
              }
            })
            box.addEventListener("paste", (e) => {
              e.preventDefault()
              fill(i, (e.clipboardData || window.clipboardData).getData("text"))
            })
            box.addEventListener("focus", () => box.select())
          })
          if (form) form.addEventListener("submit", () => { this.sent = true })
          if (!document.activeElement || document.activeElement === document.body) this.boxes[0].focus()
        }
      }
    </script>
    """
  end

  @doc """
  "O código muda em NN s": the seconds left in the current 30 second step
  of the authenticator, with a ring that empties as they run out.
  """
  attr :id, :string, required: true
  attr :seconds, :integer, required: true

  def code_timer(assigns) do
    ~H"""
    <span
      id={@id}
      class="flex items-center gap-2"
      phx-hook=".Countdown"
      phx-update="ignore"
      data-period="30"
      data-seconds={@seconds}
    >
      <svg viewBox="0 0 24 24" class="size-4" aria-hidden="true">
        <circle cx="12" cy="12" r="9" fill="none" class="auth-ring-track" stroke-width="3" />
        <circle
          cx="12"
          cy="12"
          r="9"
          fill="none"
          class="auth-ring"
          stroke-width="3"
          stroke-linecap="round"
          stroke-dasharray={"#{Float.round(56.5 * @seconds / 30, 1)} 56.5"}
          transform="rotate(-90 12 12)"
          data-ring
        />
      </svg>
      <span>
        {gettext("The code changes in")}
        <span class="font-mono text-base-content"><span data-count>{@seconds}</span> s</span>
      </span>
    </span>
    """
  end

  @doc """
  A button that waits `seconds` before it can be pressed again: "Reenviar em
  0:48", then "Reenviar link".
  """
  attr :id, :string, required: true
  attr :seconds, :integer, required: true
  attr :rest, :global

  def resend_button(assigns) do
    ~H"""
    <button
      id={@id}
      type="submit"
      class="auth-soft-button"
      disabled={@seconds > 0}
      phx-hook=".Countdown"
      data-seconds={@seconds}
      data-format="m:ss"
      {@rest}
    >
      <span data-waiting>
        {gettext("Resend in")}
        <span class="font-mono" data-count>{format_mss(@seconds)}</span>
      </span>
      <span data-ready hidden>{gettext("Resend link")}</span>
    </button>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Countdown">
      export default {
        mounted() {
          this.period = Number(this.el.dataset.period || 0)
          this.deadline = Date.now() + Number(this.el.dataset.seconds || 0) * 1000
          this.count = this.el.querySelector("[data-count]")
          this.ring = this.el.querySelector("[data-ring]")
          this.tick()
          this.timer = setInterval(() => this.tick(), 250)
        },
        tick() {
          let left
          if (this.period) {
            left = this.period - (Math.floor(Date.now() / 1000) % this.period)
          } else {
            left = Math.max(0, Math.ceil((this.deadline - Date.now()) / 1000))
          }
          if (this.count) {
            this.count.textContent = this.el.dataset.format === "m:ss"
              ? `${Math.floor(left / 60)}:${String(left % 60).padStart(2, "0")}`
              : String(left)
          }
          if (this.ring) this.ring.setAttribute("stroke-dasharray", `${(56.5 * left / this.period).toFixed(1)} 56.5`)
          if (!this.period && left === 0) {
            clearInterval(this.timer)
            this.el.disabled = false
            const waiting = this.el.querySelector("[data-waiting]")
            const ready = this.el.querySelector("[data-ready]")
            if (waiting) waiting.hidden = true
            if (ready) ready.hidden = false
          }
        },
        destroyed() { clearInterval(this.timer) }
      }
    </script>
    """
  end

  defp format_mss(seconds),
    do:
      "#{div(seconds, 60)}:#{seconds |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"

  # ── Text with markup inside ───────────────────────────────────────────────

  @doc """
  A placeholder to interpolate into a translated sentence, so a word in it
  can be wrapped in markup by `around/1` without splitting the msgid.
  """
  @spec hole() :: String.t()
  def hole, do: "\u0001"

  @doc """
  Renders `text` (a translation with one `hole/0` in it), with `value` in a
  `<span class={@class}>` where the hole is - a username in mono, say.
  """
  attr :text, :string, required: true
  attr :value, :string, required: true
  attr :class, :string, default: "font-mono"

  def around(assigns) do
    {before, rest} =
      case String.split(assigns.text, hole(), parts: 2) do
        [before, rest] -> {before, rest}
        [whole] -> {whole, nil}
      end

    assigns = assign(assigns, before: before, rest: rest)

    ~H"""
    {@before}<span :if={@rest} class={@class}>{@value}</span>{@rest}
    """
  end

  # ── Icons ─────────────────────────────────────────────────────────────────

  attr :name, :atom, required: true
  attr :class, :string, default: nil

  @doc false
  def glyph(%{name: :shield} = assigns) do
    ~H"""
    <svg
      viewBox="0 0 24 24"
      class={@class}
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <path d="M12 3 4.5 6v6c0 4.5 3.2 7.8 7.5 9 4.3-1.2 7.5-4.5 7.5-9V6L12 3z" />
    </svg>
    """
  end

  def glyph(%{name: :phone} = assigns) do
    ~H"""
    <svg
      viewBox="0 0 24 24"
      class={@class}
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <rect x="7" y="2.5" width="10" height="19" rx="2.5" /><path d="M11 18.5h2" />
    </svg>
    """
  end

  def glyph(%{name: :mail} = assigns) do
    ~H"""
    <svg
      viewBox="0 0 24 24"
      class={@class}
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <rect x="3" y="5" width="18" height="14" rx="2" /><path d="m3.5 6.5 8.5 6.5 8.5-6.5" />
    </svg>
    """
  end

  def glyph(%{name: :key} = assigns) do
    ~H"""
    <svg
      viewBox="0 0 24 24"
      class={@class}
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <circle cx="8" cy="15" r="4" /><path d="m10.8 12.2 8.7-8.7M16 7l2.5 2.5M14 9l2 2" />
    </svg>
    """
  end

  def glyph(%{name: name} = assigns) when name in [:warning, :error] do
    ~H"""
    <svg
      viewBox="0 0 24 24"
      class={@class}
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <path d="M12 4 2.5 20h19L12 4z" /><path d="M12 10v4.5M12 17.5h.01" />
    </svg>
    """
  end
end
