defmodule HllConditionalActionsWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use HllConditionalActionsWeb, :controller
      use HllConditionalActionsWeb, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      use Gettext, backend: HllConditionalActionsWeb.Gettext

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      # Tracks the current path so the sidebar can highlight where you are.
      on_mount HllConditionalActionsWeb.Nav

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      # Include general helpers for rendering HTML
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      # Translation
      use Gettext, backend: HllConditionalActionsWeb.Gettext

      # HTML escaping functionality
      import Phoenix.HTML

      # Petal Components primitives (buttons, fields, badges, alerts…).
      # Imported granularly: the app keeps its own modal, table, skeleton
      # and time components in `Ui`, so those Petal modules stay out.
      import PetalComponents.Alert
      import PetalComponents.Avatar
      import PetalComponents.Badge
      import PetalComponents.Button
      import PetalComponents.ColorSchemeSwitch
      import PetalComponents.Dropdown
      import PetalComponents.Field
      import PetalComponents.Icon
      import PetalComponents.Loading

      # Core UI components
      import HllConditionalActionsWeb.CoreComponents
      # The application's own component library (cards, stats, modals, tables…)
      import HllConditionalActionsWeb.Ui
      # The 360-view building blocks (header, tabs, KPI strip, timeline)
      import HllConditionalActionsWeb.Overview
      # Translated labels for the rule vocabulary, permissions and games
      alias HllConditionalActionsWeb.Labels
      # The icon and colour that vocabulary is drawn with
      alias HllConditionalActionsWeb.Icons

      # Common modules used in templates
      alias HllConditionalActionsWeb.Layouts
      alias Phoenix.LiveView.JS

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: HllConditionalActionsWeb.Endpoint,
        router: HllConditionalActionsWeb.Router,
        statics: HllConditionalActionsWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
