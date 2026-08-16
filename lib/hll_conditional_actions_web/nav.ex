defmodule HllConditionalActionsWeb.Nav do
  @moduledoc """
  Keeps `@current_path` in sync so the sidebar can highlight the active entry.

  Mounted for every LiveView through `HllConditionalActionsWeb.live_view/0`.
  """

  import Phoenix.Component
  import Phoenix.LiveView

  @doc false
  def on_mount(:default, _params, _session, socket) do
    {:cont,
     socket
     |> assign_new(:current_path, fn -> "/" end)
     |> attach_hook(:current_path, :handle_params, &put_current_path/3)}
  end

  defp put_current_path(_params, url, socket) do
    {:cont, assign(socket, :current_path, URI.parse(url).path || "/")}
  end
end
