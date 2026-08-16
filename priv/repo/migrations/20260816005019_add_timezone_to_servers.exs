defmodule HllConditionalActions.Repo.Migrations.AddTimezoneToServers do
  use Ecto.Migration

  def change do
    # Time-of-day conditions mean the players' local time, not the server's,
    # so each CRCON deployment carries the IANA zone of its community.
    alter table(:servers) do
      add :timezone, :string, null: false, default: "Etc/UTC"
    end
  end
end
