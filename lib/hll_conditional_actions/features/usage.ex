defmodule HllConditionalActions.Features.Usage do
  @moduledoc """
  What each marketplace module holds on a server, for the footer of its card
  ("18 regras neste servidor", "3 abertos agora"), and what a module comes
  with before it is installed ("17 receitas", "Vem com 12 conquistas").

  Everything local is a count query. The one figure that lives in CRCON -
  how many matches its history keeps - is read once per window through
  `HllConditionalActions.Players.Cache`, so however often the page is
  opened, CRCON is asked at most every ten minutes.
  """

  import Ecto.Query

  alias HllConditionalActions.Matches
  alias HllConditionalActions.Players.Cache
  alias HllConditionalActions.Progression
  alias HllConditionalActions.Progression.Achievement
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Rules.Recipes
  alias HllConditionalActions.Rules.Rule
  alias HllConditionalActions.Servers.Server
  alias HllConditionalActions.Tickets.Ticket
  alias HllConditionalActions.VipShop.Package

  # The lines the live feed page keeps on screen: `@limit` of
  # `HllConditionalActionsWeb.FeedLive`. Keep the two in step.
  @feed_lines 300

  @matches_ttl :timer.minutes(10)

  @type t :: %{
          rules: non_neg_integer(),
          tickets: non_neg_integer(),
          progression: non_neg_integer(),
          live_feed: pos_integer(),
          vip_shop: non_neg_integer()
        }

  @doc """
  The local figures of every module on a server:

    * `:rules` - the rules that apply to it (its own and the fleet-wide ones
      of its game), in any state;
    * `:tickets` - the tickets not closed yet;
    * `:progression` - the achievements it awards (its own and the global
      ones);
    * `:live_feed` - how many lines the live feed keeps;
    * `:vip_shop` - the packages on sale that grant VIP on it.
  """
  @spec for_server(Server.t()) :: t()
  def for_server(%Server{} = server) do
    %{
      rules: count_rules(server),
      tickets: count_open_tickets(server.id),
      progression: count_achievements(server.id),
      live_feed: @feed_lines,
      vip_shop: count_packages(server.id)
    }
  end

  @doc "How many recipes the rules module offers to start from."
  @spec recipes() :: non_neg_integer()
  def recipes, do: length(Recipes.all())

  @doc "How many achievements the progression module's starter set creates."
  @spec starter_achievements() :: pos_integer()
  def starter_achievements, do: Progression.starter_set_size()

  @doc "How many lines the live feed keeps."
  @spec feed_lines() :: pos_integer()
  def feed_lines, do: @feed_lines

  @doc """
  How many matches CRCON's history keeps for the server, cached for ten
  minutes (errors included, so a CRCON that is down is not asked again on
  every visit). A read: nothing is changed on the game server.
  """
  @spec saved_matches(Server.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def saved_matches(%Server{} = server) do
    Cache.fetch({__MODULE__, :saved_matches, server.id}, @matches_ttl, fn ->
      case Matches.list(server, limit: 1) do
        {:ok, %{total: total}} when is_integer(total) -> {:ok, total}
        {:ok, _other} -> {:error, :unexpected_payload}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp count_rules(%Server{id: id, game: game}) do
    Rule
    |> where([r], r.game == ^game)
    |> where([r], is_nil(r.server_id) or r.server_id == ^id)
    |> Repo.aggregate(:count)
  end

  defp count_open_tickets(server_id) do
    Ticket
    |> where([t], t.server_id == ^server_id and t.status != :closed)
    |> Repo.aggregate(:count)
  end

  defp count_achievements(server_id) do
    Achievement
    |> where([a], a.server_id == ^server_id or is_nil(a.server_id))
    |> Repo.aggregate(:count)
  end

  defp count_packages(server_id) do
    Package
    |> join(:inner, [p], s in assoc(p, :servers))
    |> where([p, s], s.id == ^server_id and p.active and is_nil(p.archived_at))
    |> select([p], count(p.id, :distinct))
    |> Repo.one()
  end
end
