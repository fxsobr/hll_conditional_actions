defmodule HllConditionalActions.Repo.Migrations.SavedEventsRetention do
  use Ecto.Migration

  # Saved events are now kept for 7 days, up to 2,000 per server and trigger,
  # instead of the latest 50 (see HllConditionalActions.Engine.SavedEvents).
  # The count prune already walks (server_id, trigger, occurred_at); with
  # forty times the rows, two other reads need an index of their own:
  #
  #   * the hourly age prune, `occurred_at < cutoff` across every server
  #   * the per server lists that span every trigger (the simulator's recent
  #     events, the briefing), newest first
  def change do
    create index(:saved_events, [:occurred_at])
    create index(:saved_events, [:server_id, :occurred_at])
  end
end
