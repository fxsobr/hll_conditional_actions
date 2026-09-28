defmodule HllConditionalActionsWeb.MarketplaceLive do
  @moduledoc """
  A server's marketplace: every optional module, what it adds, and a button
  to install or remove it.

  Removing a module hides its pages and stops its background work, but keeps
  its data - installing it again brings everything back as it was.
  """

  use HllConditionalActionsWeb, :live_view

  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :manage_servers}}

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Features
  alias HllConditionalActions.Servers
  alias HllConditionalActionsWeb.Labels

  @icons %{
    rules: "hero-bolt",
    tickets: "hero-chat-bubble-left-ellipsis",
    progression: "hero-trophy",
    stats: "hero-chart-bar",
    live_feed: "hero-signal"
  }

  @impl Phoenix.LiveView
  def mount(%{"server_id" => server_id}, _session, socket) do
    server = Servers.get_server!(server_id)

    if Accounts.can_access_server?(socket.assigns.current_user, server) do
      {:ok,
       socket
       |> assign(:server, server)
       |> assign(:page_title, gettext("Marketplace"))
       |> assign(:installed, Features.installed(server.id))}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You do not have access to that page."))
       |> push_navigate(to: ~p"/servers")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("install", %{"feature" => name}, socket) do
    with feature when not is_nil(feature) <- Features.parse(name),
         :ok <- Features.install(socket.assigns.server.id, feature, actor(socket)) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("%{module} installed.", module: Labels.feature(feature)))
       |> refresh()}
    else
      _error -> {:noreply, put_flash(socket, :error, gettext("Could not install the module."))}
    end
  end

  def handle_event("uninstall", %{"feature" => name}, socket) do
    case Features.parse(name) do
      nil ->
        {:noreply, socket}

      feature ->
        :ok = Features.uninstall(socket.assigns.server.id, feature)

        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("%{module} removed. Its data is kept for when you install it again.",
             module: Labels.feature(feature)
           )
         )
         |> refresh()}
    end
  end

  # The sidebar reads the same installations, so it is refreshed alongside
  # the cards; otherwise a new module would only show up after navigating.
  defp refresh(socket) do
    server_id = socket.assigns.server.id
    installed = Features.installed(server_id)

    nav =
      case socket.assigns[:nav] do
        %{features: features} = nav -> %{nav | features: Map.put(features, server_id, installed)}
        nav -> nav
      end

    socket |> assign(:installed, installed) |> assign(:nav, nav)
  end

  defp actor(socket), do: socket.assigns.current_user.email

  @impl Phoenix.LiveView
  def render(assigns) do
    assigns = assign(assigns, :icons, @icons)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={@page_title}
      page_subtitle={@server.name}
    >
      <p class="mb-4 max-w-2xl text-sm text-muted">
        {gettext(
          "Pick only what this server needs. Removing a module hides its pages and stops its work, but keeps its data."
        )}
      </p>

      <div id="marketplace" class="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
        <.card
          :for={feature <- Features.catalog()}
          id={"feature-#{feature}"}
          title={Labels.feature(feature)}
          icon={@icons[feature]}
          class="flex h-full flex-col gap-4"
        >
          <p class="flex-1 text-sm text-muted">{Labels.feature_description(feature)}</p>

          <div class="flex items-center justify-between gap-2">
            <%= if MapSet.member?(@installed, feature) do %>
              <.badge color="success" variant="soft" label={gettext("Installed")} />
              <.button
                id={"uninstall-#{feature}"}
                size="sm"
                variant="ghost"
                color="gray"
                icon="hero-minus-circle"
                phx-click="uninstall"
                phx-value-feature={feature}
                data-confirm={gettext("Remove this module from the server?")}
                label={gettext("Remove")}
              />
            <% else %>
              <.badge color="gray" variant="soft" label={gettext("Available")} />
              <.button
                id={"install-#{feature}"}
                size="sm"
                icon="hero-plus"
                phx-click="install"
                phx-value-feature={feature}
                label={gettext("Install")}
              />
            <% end %>
          </div>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
