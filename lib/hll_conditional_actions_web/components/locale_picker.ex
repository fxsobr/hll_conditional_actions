defmodule HllConditionalActionsWeb.LocalePicker do
  @moduledoc """
  The language menu shown on every screen: the current language's flag,
  opening a list of every supported language with its flag and native name.

  Flags are small inline SVGs rather than emoji, which Windows renders as two
  letters. A choice goes through `/locale/:locale`, which stores it in the
  session and comes back to the same page.
  """

  use Phoenix.Component

  alias HllConditionalActionsWeb.Plugs.Locale

  attr :return_to, :string, default: "/"
  attr :class, :any, default: nil
  attr :align, :string, default: "right", values: ~w(left right)

  attr :tone, :string,
    default: "app",
    values: ~w(app shop overlay),
    doc: "app: admin colours; shop: the storefront's tokens; overlay: over artwork"

  def locale_picker(assigns) do
    assigns =
      assigns
      |> assign(:current, Gettext.get_locale(HllConditionalActionsWeb.Gettext))
      |> assign(:locales, Locale.supported())

    ~H"""
    <details :if={length(@locales) > 1} class={["group relative", @class]}>
      <summary
        class={[
          "flex cursor-pointer list-none items-center gap-1.5 rounded-full px-2 py-1.5 text-sm transition [&::-webkit-details-marker]:hidden",
          summary_tone(@tone)
        ]}
        aria-label={label(@current)}
      >
        <.flag locale={@current} />
        <span class="hidden sm:inline">{short(@current)}</span>
        <svg
          class="size-3.5 opacity-60 transition group-open:rotate-180"
          viewBox="0 0 20 20"
          fill="currentColor"
          aria-hidden="true"
        >
          <path
            fill-rule="evenodd"
            d="M5.23 7.21a.75.75 0 0 1 1.06.02L10 11.06l3.71-3.83a.75.75 0 1 1 1.08 1.04l-4.25 4.39a.75.75 0 0 1-1.08 0L5.21 8.27a.75.75 0 0 1 .02-1.06Z"
            clip-rule="evenodd"
          />
        </svg>
      </summary>
      <ul class={[
        "absolute z-50 mt-2 min-w-44 overflow-hidden rounded-xl border p-1 shadow-xl",
        if(@align == "right", do: "right-0", else: "left-0"),
        menu_tone(@tone)
      ]}>
        <li :for={locale <- @locales}>
          <a
            href={"/locale/#{locale}?" <> URI.encode_query(return_to: @return_to)}
            class={[
              "flex items-center gap-2.5 rounded-lg px-3 py-2 text-sm transition",
              item_tone(@tone, locale == @current)
            ]}
          >
            <.flag locale={locale} />
            <span class="flex-1">{label(locale)}</span>
            <svg
              :if={locale == @current}
              class="size-4"
              viewBox="0 0 20 20"
              fill="currentColor"
              aria-hidden="true"
            >
              <path
                fill-rule="evenodd"
                d="M16.7 5.3a1 1 0 0 1 0 1.4l-8 8a1 1 0 0 1-1.4 0l-4-4a1 1 0 1 1 1.4-1.4L8 12.58l7.3-7.3a1 1 0 0 1 1.4 0Z"
                clip-rule="evenodd"
              />
            </svg>
          </a>
        </li>
      </ul>
    </details>
    """
  end

  attr :locale, :string, required: true

  @doc "A small rounded flag for a locale."
  def flag(%{locale: "pt_BR"} = assigns) do
    ~H"""
    <svg
      class="h-3.5 w-5 shrink-0 overflow-hidden rounded-[3px] ring-1 ring-black/10"
      viewBox="0 0 20 14"
      aria-hidden="true"
    >
      <rect width="20" height="14" fill="#009c3b" />
      <path d="M10 1.6 18.2 7 10 12.4 1.8 7Z" fill="#ffdf00" />
      <circle cx="10" cy="7" r="3.1" fill="#002776" />
      <path d="M7.1 6.4c1.9-.5 4-.3 5.8.6" stroke="#fff" stroke-width=".6" fill="none" />
    </svg>
    """
  end

  def flag(%{locale: "es"} = assigns) do
    ~H"""
    <svg
      class="h-3.5 w-5 shrink-0 overflow-hidden rounded-[3px] ring-1 ring-black/10"
      viewBox="0 0 20 14"
      aria-hidden="true"
    >
      <rect width="20" height="14" fill="#aa151b" />
      <rect y="3.5" width="20" height="7" fill="#f1bf00" />
    </svg>
    """
  end

  def flag(assigns) do
    ~H"""
    <svg
      class="h-3.5 w-5 shrink-0 overflow-hidden rounded-[3px] ring-1 ring-black/10"
      viewBox="0 0 20 14"
      aria-hidden="true"
    >
      <rect width="20" height="14" fill="#fff" />
      <path
        d="M0 0h20v1.08H0zm0 2.15h20v1.08H0zm0 2.15h20v1.08H0zm0 2.16h20v1.07H0zm0 2.15h20v1.08H0zm0 2.15h20v1.08H0zm0 2.16h20V14H0z"
        fill="#b22234"
      />
      <rect width="8.4" height="7.54" fill="#3c3b6e" />
    </svg>
    """
  end

  defp label("pt_BR"), do: "Português (Brasil)"
  defp label("es"), do: "Español"
  defp label("en"), do: "English"
  defp label(other), do: other

  defp short("pt_BR"), do: "PT"
  defp short("es"), do: "ES"
  defp short("en"), do: "EN"
  defp short(other), do: String.upcase(other)

  defp summary_tone("shop"),
    do: "text-[var(--shop-muted)] hover:bg-[var(--shop-surface)] hover:text-[var(--shop-text)]"

  defp summary_tone("overlay"),
    do: "bg-white/10 text-white ring-1 ring-white/15 backdrop-blur hover:bg-white/20"

  defp summary_tone(_app), do: "text-muted hover:bg-base-200 hover:text-base-content"

  defp menu_tone("shop"),
    do: "border-[var(--shop-border)] bg-[var(--shop-surface)] text-[var(--shop-text)]"

  defp menu_tone(_other), do: "border-base-300 bg-base-100 text-base-content"

  defp item_tone("shop", true),
    do: "bg-[var(--shop-accent)]/15 font-medium text-[var(--shop-accent)]"

  defp item_tone("shop", false), do: "hover:bg-[var(--shop-bg)]"
  defp item_tone(_other, true), do: "bg-primary/10 font-medium text-primary"
  defp item_tone(_other, false), do: "hover:bg-base-200"
end
