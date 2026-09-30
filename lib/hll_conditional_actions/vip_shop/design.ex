defmodule HllConditionalActions.VipShop.Design do
  @moduledoc """
  How the public shop looks, as a small design system instead of loose
  colours.

  An admin makes three choices, each from a curated set, so any combination
  still looks deliberate:

    * **theme** - a palette of design tokens (background, surface, border,
      text, muted text, accent and the text colour on the accent) tuned to
      keep contrast readable. The accent can be overridden with the brand
      colour; the text on it is picked for contrast automatically.
    * **hero** - how the top of the page is laid out: a full cover over the
      banner, a split with the image beside the text, or a minimal header.
    * **sections** - which blocks the page shows and in what order:
      benefits, packages, servers, frequently asked questions and a closing
      call to action.

  Benefits and questions are short lists the admin writes; until they do,
  the page shows translated examples. Everything is
  stored in the settings' `design` map and read through `get/1`, which fills
  whatever is missing with defaults.
  """

  @themes %{
    "tactical" => %{
      bg: "#0f1210",
      surface: "#171c18",
      border: "#2a322b",
      text: "#e8ece6",
      muted: "#9aa597",
      accent: "#8fb04a"
    },
    "crimson" => %{
      bg: "#110d0e",
      surface: "#1b1416",
      border: "#33262a",
      text: "#f1e9ea",
      muted: "#a8979a",
      accent: "#d9383f"
    },
    "midnight" => %{
      bg: "#0b1020",
      surface: "#121a2e",
      border: "#223050",
      text: "#e6ecf8",
      muted: "#94a3c2",
      accent: "#3fa7ff"
    },
    "desert" => %{
      bg: "#f5efe4",
      surface: "#fffaf1",
      border: "#e3d6bf",
      text: "#2c2418",
      muted: "#7a6a52",
      accent: "#b8621b"
    },
    "arctic" => %{
      bg: "#f4f7fb",
      surface: "#ffffff",
      border: "#dde5ef",
      text: "#152033",
      muted: "#5c6b82",
      accent: "#2563eb"
    }
  }

  @heroes ~w(cover split minimal)
  @sections ~w(benefits packages servers faq cta)
  @icons ~w(bolt star shield-check clock trophy user-group chat-bubble-left-right heart fire rocket-launch sparkles check-badge)

  @defaults %{
    "theme" => "tactical",
    "accent" => nil,
    "hero" => "cover",
    "uppercase" => true,
    "cta_label" => nil,
    # Section headings the admin rewrote; missing ones use the translated
    # defaults.
    "titles" => %{},
    # The sign in and sign up screens: a split page with the form on one side
    # and an image on the other. Missing texts use translated defaults; with
    # no image of its own the page reuses the banner.
    "auth" => %{"image_id" => nil, "side" => "right", "show_benefits" => true, "texts" => %{}},
    "sections" =>
      Enum.map(@sections, &%{"key" => &1, "enabled" => &1 in ~w(benefits packages faq)}),
    # nil until the admin writes their own: the page then shows translated
    # examples (see `HllConditionalActionsWeb.ShopComponents`).
    "benefits" => nil,
    "faq" => nil
  }

  @doc "The theme names, in display order."
  @spec themes() :: [String.t()]
  def themes, do: ~w(tactical crimson midnight desert arctic)

  @doc "A theme's tokens."
  @spec theme(String.t()) :: map()
  def theme(name), do: Map.get(@themes, name, @themes["tactical"])

  @doc "The hero layouts."
  @spec heroes() :: [String.t()]
  def heroes, do: @heroes

  @doc "The page sections."
  @spec section_keys() :: [String.t()]
  def section_keys, do: @sections

  @doc "The headings and texts of the sections an admin can rewrite."
  @spec title_keys() :: [String.t()]
  def title_keys,
    do: ~w(hero benefits packages packages_subtitle servers faq cta cta_subtitle)

  @doc "The texts of the sign in and sign up screens an admin can rewrite."
  @spec auth_text_keys() :: [String.t()]
  def auth_text_keys,
    do: ~w(login_title login_subtitle register_title register_subtitle panel_title panel_text)

  @doc "The icons a benefit can use (heroicon names without the prefix)."
  @spec icons() :: [String.t()]
  def icons, do: @icons

  @doc """
  The stored design with defaults filled in, and every section listed once.
  """
  @spec get(map() | nil) :: map()
  def get(stored) do
    design = Map.merge(@defaults, stored || %{})
    design = %{design | "auth" => Map.merge(@defaults["auth"], design["auth"] || %{})}

    listed =
      design["sections"] |> Enum.filter(&(&1["key"] in @sections)) |> Enum.uniq_by(& &1["key"])

    missing =
      for key <- @sections,
          key not in Enum.map(listed, & &1["key"]),
          do: %{"key" => key, "enabled" => false}

    %{design | "sections" => listed ++ missing}
  end

  @doc "The enabled sections, in order."
  @spec enabled_sections(map()) :: [String.t()]
  def enabled_sections(design),
    do: for(%{"key" => key, "enabled" => true} <- design["sections"], do: key)

  @doc """
  The CSS custom properties for a design, as an inline `style` value.

      iex> style = HllConditionalActions.VipShop.Design.css_vars(%{"theme" => "arctic", "accent" => "#ffcc00"})
      iex> style =~ "--shop-accent: #ffcc00" and style =~ "--shop-on-accent: #111111"
      true
  """
  @spec css_vars(map()) :: String.t()
  def css_vars(design) do
    tokens = theme(design["theme"])
    accent = valid_color(design["accent"]) || tokens.accent

    [
      {"bg", tokens.bg},
      {"surface", tokens.surface},
      {"border", tokens.border},
      {"text", tokens.text},
      {"muted", tokens.muted},
      {"accent", accent},
      {"on-accent", on_color(accent)}
    ]
    |> Enum.map_join("; ", fn {name, value} -> "--shop-#{name}: #{value}" end)
  end

  @doc """
  Black or white, whichever reads better on a colour (WCAG relative
  luminance).

      iex> HllConditionalActions.VipShop.Design.on_color("#ffffff")
      "#111111"
      iex> HllConditionalActions.VipShop.Design.on_color("#1d4ed8")
      "#ffffff"
  """
  @spec on_color(String.t()) :: String.t()
  def on_color("#" <> hex) do
    [r, g, b] =
      for <<pair::binary-size(2) <- hex>> do
        c = String.to_integer(pair, 16) / 255
        if c <= 0.03928, do: c / 12.92, else: :math.pow((c + 0.055) / 1.055, 2.4)
      end

    if 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.4, do: "#111111", else: "#ffffff"
  end

  @doc """
  Reads the design form: sections in the order given, benefits and questions
  without their blank rows.
  """
  @spec from_params(map(), map()) :: map()
  def from_params(params, current) do
    %{
      "theme" => pick(params["theme"], themes(), current["theme"]),
      # A colour input always sends a value; it only counts when the admin
      # asked for their own colour instead of the theme's.
      "accent" =>
        if(params["custom_accent"] in ["true", true],
          do:
            valid_color(params["accent"]) ||
              theme(pick(params["theme"], themes(), current["theme"])).accent
        ),
      "hero" => pick(params["hero"], @heroes, current["hero"]),
      "uppercase" => params["uppercase"] in ["true", true],
      "cta_label" => blank_to_nil(params["cta_label"]),
      "auth" => auth_from_params(params["auth"] || %{}, current["auth"] || %{}),
      "titles" =>
        (params["titles"] || %{})
        |> Map.take(title_keys())
        |> Map.new(fn {key, value} -> {key, blank_to_nil(value)} end)
        |> Map.reject(fn {_key, value} -> is_nil(value) end),
      "sections" =>
        Enum.map(current["sections"], fn %{"key" => key} ->
          %{"key" => key, "enabled" => get_in(params, ["sections", key]) in ["true", true]}
        end),
      "benefits" =>
        params
        |> rows("benefits")
        |> Enum.map(
          &%{
            "icon" => pick(&1["icon"], @icons, "star"),
            "title" => trim(&1["title"]),
            "text" => trim(&1["text"])
          }
        )
        |> Enum.reject(&(&1["title"] == "")),
      "faq" =>
        params
        |> rows("faq")
        |> Enum.map(&%{"q" => trim(&1["q"]), "a" => trim(&1["a"])})
        |> Enum.reject(&(&1["q"] == ""))
    }
  end

  @doc "Moves a section one place up or down."
  @spec move_section(map(), String.t(), :up | :down) :: map()
  def move_section(design, key, direction) do
    sections = design["sections"]
    index = Enum.find_index(sections, &(&1["key"] == key))
    target = if direction == :up, do: index - 1, else: index + 1

    if (index && target >= 0) and target < length(sections) do
      a = Enum.at(sections, index)
      b = Enum.at(sections, target)

      %{
        design
        | "sections" => sections |> List.replace_at(index, b) |> List.replace_at(target, a)
      }
    else
      design
    end
  end

  # The image is uploaded separately; it is kept unless the form removes it.
  defp auth_from_params(params, current) do
    %{
      "image_id" => if(params["remove_image"] == "true", do: nil, else: current["image_id"]),
      "side" => pick(params["side"], ~w(left right), current["side"] || "right"),
      "show_benefits" => params["show_benefits"] in ["true", true],
      "texts" =>
        (params["texts"] || %{})
        |> Map.take(auth_text_keys())
        |> Map.new(fn {key, value} -> {key, blank_to_nil(value)} end)
        |> Map.reject(fn {_key, value} -> is_nil(value) end)
    }
  end

  # Rows arrive as %{"0" => %{...}, "1" => %{...}}; keep their order.
  defp rows(params, key) do
    params
    |> Map.get(key, %{})
    |> Enum.sort_by(fn {index, _row} -> String.to_integer(index) end)
    |> Enum.map(&elem(&1, 1))
  end

  defp pick(value, allowed, fallback), do: if(value in allowed, do: value, else: fallback)

  defp valid_color(value) when is_binary(value),
    do: if(value =~ ~r/^#[0-9a-fA-F]{6}$/, do: String.downcase(value))

  defp valid_color(_value), do: nil
  defp trim(value), do: value |> to_string() |> String.trim()
  defp blank_to_nil(value), do: if(trim(value) == "", do: nil, else: trim(value))
end
