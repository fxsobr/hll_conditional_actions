defmodule HllConditionalActions.Fixtures do
  @moduledoc """
  Test data builders.

  Every fixture takes an attribute map that overrides its defaults, so a test
  only has to state what it actually cares about.
  """

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Servers

  @doc """
  A CRCON server. Defaults to Hell Let Loose (WW2).
  """
  def server_fixture(attrs \\ %{}) do
    {:ok, server} =
      attrs
      |> Enum.into(%{
        name: "Server #{System.unique_integer([:positive])}",
        game: :hll,
        base_url: "https://rcon.example.com",
        api_key: "test-api-key"
      })
      |> Servers.create_server()

    server
  end

  @doc """
  A rule. Defaults to "message the player when they connect", with no
  conditions beyond `always_true`.
  """
  def rule_fixture(attrs \\ %{}, opts \\ []) do
    {:ok, rule} =
      attrs
      |> Enum.into(%{
        name: "Rule #{System.unique_integer([:positive])}",
        game: :hll,
        trigger_event: :player_connected,
        logical_operator: :and,
        conditions: [%{field: :always_true, operator: :equal, value: ""}],
        actions: [%{type: :message_player, parameters: %{"message" => "Welcome!"}}]
      })
      |> Rules.create_rule(opts)

    rule
  end

  @doc """
  A user. Defaults to the Administrator role.
  """
  def user_fixture(attrs \\ %{}) do
    role = Map.get_lazy(attrs, :role, fn -> Accounts.ensure_system_roles!().administrator end)

    {:ok, user} =
      attrs
      |> Map.drop([:role])
      |> Enum.into(%{
        username: "user#{System.unique_integer([:positive])}",
        name: "Test User",
        password: "supersecret123",
        password_confirmation: "supersecret123",
        role_id: role.id
      })
      |> Accounts.create_user()

    user
  end

  @doc """
  A role with the given permissions.
  """
  def role_fixture(attrs \\ %{}) do
    {:ok, role} =
      attrs
      |> Enum.into(%{
        name: "Role #{System.unique_integer([:positive])}",
        permissions: ["view_servers"]
      })
      |> Accounts.create_role()

    role
  end

  @doc """
  A player entry shaped like CRCON's `get_detailed_players` payload.
  """
  def player(attrs \\ %{}) do
    Enum.into(attrs, %{
      "name" => "Chris",
      "player_id" => "76561190000000001",
      "level" => 42,
      "is_vip" => false,
      "team" => "allies",
      "role" => "rifleman",
      "unit_name" => "able",
      "clan_tag" => "",
      "platform" => "steam",
      "kills" => 10,
      "deaths" => 5,
      "team_kills" => 0,
      "combat" => 100,
      "offense" => 80,
      "defense" => 60,
      "support" => 40,
      "map_playtime_seconds" => 600
    })
  end

  @doc """
  A game state shaped like CRCON's `get_gamestate` payload.
  """
  def gamestate(attrs \\ %{}) do
    Enum.into(attrs, %{
      "num_allied_players" => 25,
      "num_axis_players" => 24,
      "allied_score" => 2,
      "axis_score" => 3,
      "raw_time_remaining" => "1:02:03",
      "game_mode" => "warfare",
      "queue_count" => 3,
      "current_map" => %{
        "id" => "carentan_warfare",
        "pretty_name" => "Carentan Warfare",
        "map" => %{"pretty_name" => "Carentan"}
      }
    })
  end

  @doc """
  A structured log line shaped like the CRCON log stream payload.
  """
  def log_line(attrs \\ %{}) do
    Enum.into(attrs, %{
      "action" => "KILL",
      "player_name_1" => "Chris",
      "player_id_1" => "76561190000000001",
      "player_name_2" => "Muctar",
      "player_id_2" => "76561190000000002",
      "weapon" => "M1 GARAND",
      "message" => "Chris -> Muctar with M1 GARAND",
      "sub_content" => nil,
      "timestamp_ms" => 1_700_000_000_000
    })
  end
end
