defmodule HllConditionalActions.FeaturesTest do
  use HllConditionalActions.DataCase, async: true

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Features

  doctest Features

  test "a new server starts with nothing installed" do
    {:ok, server} =
      HllConditionalActions.Servers.create_server(%{
        name: "Fresh",
        game: :hll,
        base_url: "https://rcon.example.com",
        api_key: "key"
      })

    assert Features.installed(server.id) == MapSet.new()
  end

  test "install and uninstall change the set and broadcast" do
    server = server_fixture(%{features: []})
    Features.subscribe()

    assert :ok = Features.install(server.id, :tickets, "admin@example.com")
    assert_receive {:features_changed, id} when id == server.id
    assert Features.installed?(server.id, :tickets)

    # Installing twice is harmless.
    assert :ok = Features.install(server.id, :tickets)
    assert Features.installed(server.id) == MapSet.new([:tickets])

    assert :ok = Features.uninstall(server.id, :tickets)
    refute Features.installed?(server.id, :tickets)
  end

  test "installed_by_server maps every server, even empty ones" do
    a = server_fixture(%{features: [:rules]})
    b = server_fixture(%{features: []})

    assert %{} = map = Features.installed_by_server([a.id, b.id])
    assert map[a.id] == MapSet.new([:rules])
    assert map[b.id] == MapSet.new()
  end

  test "installations go away with the server" do
    server = server_fixture(%{features: [:rules]})
    {:ok, _server} = HllConditionalActions.Servers.delete_server(server)

    assert Features.installed(server.id) == MapSet.new()
  end
end
