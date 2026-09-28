defmodule HllConditionalActionsWeb.FeatureGuard do
  @moduledoc """
  Keeps pages of a marketplace module out of reach until it is installed.

  A page under `/servers/:server_id/...` needs the module on that server; an
  organisation page needs it on at least one server the user can see (or no
  server to exist yet). Anyone
  who arrives anyway - an old bookmark, a typed URL - lands on the
  marketplace of the server with a note saying what is missing.

  Mounted for the whole authenticated `live_session`, so a new page only has
  to be added to `feature_of/1`.
  """

  use Gettext, backend: HllConditionalActionsWeb.Gettext

  import Phoenix.LiveView

  alias HllConditionalActions.Features
  alias HllConditionalActions.Servers
  alias HllConditionalActionsWeb.Labels

  @doc false
  def on_mount(:default, params, _session, socket) do
    case feature_of(socket.view) do
      nil -> {:cont, socket}
      feature -> check(feature, params, socket)
    end
  end

  defp check(feature, %{"server_id" => server_id}, socket) do
    if Features.installed?(server_id, feature),
      do: {:cont, socket},
      else: {:halt, missing(socket, feature, "/servers/#{server_id}/marketplace")}
  end

  defp check(feature, _params, socket) do
    ids = socket.assigns[:current_user] |> Servers.list_servers_for() |> Enum.map(& &1.id)

    # With no server yet there is nothing to install on, and the page's own
    # empty state explains more than a redirect would.
    installed? = Enum.any?(Features.installed_by_server(ids), fn {_id, set} -> feature in set end)

    if ids == [] or installed?,
      do: {:cont, socket},
      else: {:halt, missing(socket, feature, "/servers")}
  end

  defp missing(socket, feature, to) do
    socket
    |> put_flash(
      :error,
      gettext("The %{module} module is not installed. Install it from the marketplace.",
        module: Labels.feature(feature)
      )
    )
    |> redirect(to: to)
  end

  # The page namespace, under HllConditionalActionsWeb, that each module owns.
  @pages %{
    "RuleLive" => :rules,
    "ExecutionLive" => :rules,
    "TicketLive" => :tickets,
    "SeasonLive" => :progression,
    "AchievementLive" => :progression,
    "LeaderboardLive" => :stats,
    "MatchLive" => :stats,
    "FeedLive" => :live_feed
  }

  @doc """
  The marketplace module a LiveView belongs to, or nil for the core.

      iex> HllConditionalActionsWeb.FeatureGuard.feature_of(HllConditionalActionsWeb.FeedLive)
      :live_feed
      iex> HllConditionalActionsWeb.FeatureGuard.feature_of(HllConditionalActionsWeb.DashboardLive)
      nil
  """
  @spec feature_of(module()) :: Features.feature() | nil
  def feature_of(view) do
    case Module.split(view) do
      [_app, page | _rest] -> Map.get(@pages, page)
      _other -> nil
    end
  end
end
