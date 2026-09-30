defmodule HllConditionalActionsWeb.BrandIcons do
  @moduledoc """
  The official logos of the social networks the VIP shop links to, from
  Simple Icons (CC0). The SVG paths are read from the `simple_icons`
  dependency at compile time, so only these few paths end up in the app.
  """

  use Phoenix.Component

  @networks ~w(discord instagram youtube twitch tiktok x facebook)
  @dir Path.join([Mix.Project.deps_path(), "simple_icons", "icons"])

  @paths Map.new(@networks, fn name ->
           file = Path.join(@dir, "#{name}.svg")
           @external_resource file
           [_all, path] = Regex.run(~r/<path d="([^"]+)"/, File.read!(file))
           {name, path}
         end)

  @doc "Whether a network has a brand icon."
  @spec brand?(String.t()) :: boolean()
  def brand?(network), do: Map.has_key?(@paths, network)

  attr :name, :string, required: true
  attr :class, :any, default: "size-5"

  @doc "A network's logo, in the current text colour."
  def brand_icon(assigns) do
    assigns = assign(assigns, :path, Map.get(@paths, assigns.name))

    ~H"""
    <svg :if={@path} class={@class} viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d={@path} />
    </svg>
    """
  end
end
