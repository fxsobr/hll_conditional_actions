defmodule HllConditionalActions.Features.Installation do
  @moduledoc """
  One marketplace module installed on one server.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias HllConditionalActions.Servers.Server

  schema "feature_installations" do
    field :feature, :string
    field :installed_by, :string

    belongs_to :server, Server

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(installation, attrs) do
    installation
    |> cast(attrs, [:server_id, :feature, :installed_by])
    |> validate_required([:server_id, :feature])
    |> validate_inclusion(
      :feature,
      Enum.map(HllConditionalActions.Features.catalog(), &to_string/1)
    )
    |> foreign_key_constraint(:server_id)
    |> unique_constraint([:server_id, :feature])
  end
end
