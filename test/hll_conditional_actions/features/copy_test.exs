defmodule HllConditionalActions.Features.CopyTest do
  use HllConditionalActions.DataCase, async: true

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Features
  alias HllConditionalActions.Features.Copy

  doctest HllConditionalActions.Features.ShopKey

  test "plans the modules to install and the extras, in marketplace order" do
    source = server_fixture(%{features: [:vip_shop, :rules, :tickets]})
    target = server_fixture(%{features: [:rules, :live_feed]})

    assert Copy.plan(source.id, target.id) == %{
             install: [:tickets, :vip_shop],
             extra: [:live_feed]
           }
  end

  test "installs the missing modules, keeps the extras and tells the runtime once" do
    source = server_fixture(%{features: [:rules, :tickets, :stats]})
    target = server_fixture(%{features: [:live_feed]})
    Features.subscribe()

    assert {:ok, %{installed: [:rules, :tickets, :stats], removed: []}} =
             Copy.copy(source.id, target.id, actor: "ana@example.com")

    assert Features.installed(target.id) == MapSet.new([:rules, :tickets, :stats, :live_feed])
    assert Features.installed(source.id) == MapSet.new([:rules, :tickets, :stats])

    target_id = target.id
    assert_received {:features_changed, ^target_id}
    refute_received {:features_changed, ^target_id}
  end

  test "removes the extras when asked" do
    source = server_fixture(%{features: [:rules]})
    target = server_fixture(%{features: [:rules, :vip_shop, :progression]})

    assert {:ok, %{installed: [], removed: [:progression, :vip_shop]}} =
             Copy.copy(source.id, target.id, remove_extras: true)

    assert Features.installed(target.id) == MapSet.new([:rules])
  end

  test "changes nothing, and tells nobody, when the sets already match" do
    source = server_fixture(%{features: [:rules]})
    target = server_fixture(%{features: [:rules]})
    Features.subscribe()

    assert {:ok, %{installed: [], removed: []}} = Copy.copy(source.id, target.id)

    target_id = target.id
    refute_received {:features_changed, ^target_id}
  end

  test "refuses to copy a server onto itself" do
    server = server_fixture(%{features: [:rules]})
    assert {:error, :same_server} = Copy.copy(server.id, server.id)
  end
end
