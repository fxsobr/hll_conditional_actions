defmodule HllConditionalActions.Engine.SavedEventsTest do
  @moduledoc """
  Retention of the saved events behind the builder's "7-day replay": a week
  at most, and at most `SavedEvents.keep/0` per server and trigger.
  """

  use HllConditionalActions.DataCase, async: true

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Engine.Samples
  alias HllConditionalActions.Engine.SavedEvent
  alias HllConditionalActions.Engine.SavedEvents
  alias HllConditionalActions.Rules.Bench
  alias HllConditionalActions.Workers.PruneSavedEvents

  defp sample(server, trigger, n, at) do
    %{
      server_id: server.id,
      trigger: trigger,
      player_id: "p#{n}",
      player_name: "P#{n}",
      player: %{"player_id" => "p#{n}", "name" => "P#{n}"},
      player_profile: nil,
      gamestate: nil,
      squad: %{},
      ranks: %{},
      event: nil,
      at: at,
      at_us: DateTime.to_unix(at, :microsecond)
    }
  end

  # `count` events of a trigger, one a second, the newest `newest` ago.
  defp samples(server, trigger, count, newest \\ 60) do
    first = DateTime.add(DateTime.utc_now(), -(newest + count), :second)

    for n <- 1..count, do: sample(server, trigger, n, DateTime.add(first, n, :second))
  end

  defp stored(server, trigger) do
    Repo.aggregate(
      from(e in SavedEvent,
        where: e.server_id == ^server.id and e.trigger == ^to_string(trigger)
      ),
      :count
    )
  end

  test "the policy: a week, capped per server and trigger" do
    assert SavedEvents.retention_days() == 7
    assert SavedEvents.keep() == 2_000
    assert Bench.days() == SavedEvents.retention_days()
    # The ring warmed from disk and the bench's replay never read past it.
    assert Samples.capacity() < SavedEvents.keep()
    assert Bench.replay_limit() <= SavedEvents.keep()
  end

  describe "pruning by count" do
    test "keeps the newest keep/0 of each server and trigger" do
      server = server_fixture()
      other = server_fixture()
      keep = SavedEvents.keep()

      SavedEvents.store(samples(server, :player_kill, keep + 5))
      SavedEvents.store(samples(server, :player_death, 3))
      SavedEvents.store(samples(other, :player_kill, 4))

      assert stored(server, :player_kill) == keep

      [newest | _rest] = SavedEvents.list([server.id], trigger: :player_kill, limit: 1)
      assert newest.sample.player_name == "P#{keep + 5}"

      oldest =
        Repo.one(
          from e in SavedEvent,
            where: e.server_id == ^server.id and e.trigger == "player_kill",
            order_by: [asc: e.occurred_at],
            limit: 1,
            select: e.player_name
        )

      # The five oldest went; the sixth is the oldest kept.
      assert oldest == "P6"

      # Other pairs are neither counted with it nor touched.
      assert stored(server, :player_death) == 3
      assert stored(other, :player_kill) == 4
    end

    test "only prunes the pairs it is asked to" do
      server = server_fixture()
      keep = SavedEvents.keep()

      SavedEvents.store(samples(server, :player_kill, keep + 3), prune: [])
      assert stored(server, :player_kill) == keep + 3

      assert SavedEvents.prune_count(server.id, :player_kill) == 3
      assert stored(server, :player_kill) == keep

      # Under the cap there is nothing to delete.
      assert SavedEvents.prune_count(server.id, :player_kill) == 0
    end

    test "the recorder prunes a pair once it may be over the cap, not on every write" do
      server = server_fixture()
      keep = SavedEvents.keep()
      slack = SavedEvents.prune_slack()
      key = {server.id, :player_kill}

      SavedEvents.store(samples(server, :player_kill, keep + 3, 120), prune: [])

      one_more = fn n -> [sample(server, :player_kill, keep + 3 + n, DateTime.utc_now())] end

      # A pair not seen since the start is pruned on its first write...
      state = Samples.flush(%{pending: %{key => one_more.(1)}, unpruned: %{}})
      assert stored(server, :player_kill) == keep
      assert state.unpruned[key] == 0

      # ...then left alone while it grows by less than the slack...
      state = Samples.flush(%{state | pending: %{key => one_more.(2)}})
      assert stored(server, :player_kill) == keep + 1
      assert state.unpruned[key] == 1

      # ...and cut back once the slack is reached.
      state =
        Samples.flush(%{pending: %{key => one_more.(3)}, unpruned: %{key => slack - 1}})

      assert stored(server, :player_kill) == keep
      assert state.unpruned[key] == 0
      assert state.pending == %{}
    end
  end

  describe "pruning by age" do
    test "deletes what is older than retention_days/0, on every server" do
      server = server_fixture()
      other = server_fixture()
      now = DateTime.utc_now()
      days = SavedEvents.retention_days()

      old = DateTime.add(now, -(days * 24 + 1), :hour)
      recent = DateTime.add(now, -(days * 24 - 1), :hour)

      SavedEvents.store([
        sample(server, :player_kill, 1, old),
        sample(server, :player_kill, 2, recent),
        sample(server, :player_connected, 3, old),
        sample(other, :player_kill, 4, old),
        sample(other, :player_kill, 5, now)
      ])

      assert SavedEvents.prune_old(now) == 3

      names =
        Repo.all(
          from e in SavedEvent,
            where: e.server_id in ^[server.id, other.id],
            order_by: e.player_name,
            select: e.player_name
        )

      assert names == ["P2", "P5"]
    end

    test "runs from the hourly worker" do
      server = server_fixture()
      old = DateTime.add(DateTime.utc_now(), -(SavedEvents.retention_days() + 1), :day)

      SavedEvents.store([
        sample(server, :player_kill, 1, old),
        sample(server, :player_kill, 2, DateTime.utc_now())
      ])

      assert PruneSavedEvents.perform(%Oban.Job{}) == :ok
      assert stored(server, :player_kill) == 1
    end
  end

  test "warming the ring reads back only its capacity per pair, oldest first" do
    server = server_fixture()

    SavedEvents.store(samples(server, :player_kill, 5))
    SavedEvents.store(samples(server, :player_death, 2))

    warmed =
      3
      |> SavedEvents.latest_samples()
      |> Enum.filter(&(&1.server_id == server.id))

    assert warmed |> Enum.filter(&(&1.trigger == :player_kill)) |> Enum.map(& &1.player_name) ==
             ["P3", "P4", "P5"]

    assert warmed |> Enum.filter(&(&1.trigger == :player_death)) |> length() == 2
  end
end
