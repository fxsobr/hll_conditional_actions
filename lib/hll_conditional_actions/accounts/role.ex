defmodule HllConditionalActions.Accounts.Role do
  @moduledoc """
  A named set of permissions.

  Three roles are seeded on first boot and marked `system?`, which keeps them
  from being deleted:

    * **Administrator** - every permission, including platform administration
    * **Operator** - can write rules and watch what they do, but cannot change
      server credentials or user access
    * **Viewer** - read only

  Any number of custom roles can be added on top.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias HllConditionalActions.Accounts.Permission
  alias HllConditionalActions.Accounts.User

  @type t :: %__MODULE__{}

  schema "roles" do
    field :name, :string
    field :description, :string
    field :permissions, {:array, :string}, default: []
    field :system?, :boolean, source: :system, default: false

    has_many :users, User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for a role.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(role, attrs) do
    role
    |> cast(attrs, [:name, :description, :permissions])
    |> validate_required([:name])
    |> validate_length(:name, min: 2, max: 60)
    |> clean_permissions()
    |> unique_constraint(:name)
  end

  @doc """
  Whether a role grants a permission, taking implications into account.

      iex> alias HllConditionalActions.Accounts.Role
      iex> role = %Role{permissions: ["manage_servers"]}
      iex> {Role.can?(role, :view_servers), Role.can?(role, :manage_users)}
      {true, false}
  """
  @spec can?(t() | nil, atom() | String.t()) :: boolean()
  def can?(nil, _permission), do: false

  def can?(%__MODULE__{permissions: permissions}, permission) do
    to_string(permission) in Permission.expand(permissions)
  end

  # Forms post unchecked boxes as "false"; keep only real permission names so a
  # typo or a stale form value cannot grant something that does not exist.
  defp clean_permissions(changeset) do
    case get_change(changeset, :permissions) do
      nil ->
        changeset

      permissions ->
        cleaned =
          permissions
          |> Enum.map(&to_string/1)
          |> Enum.filter(&Permission.valid?/1)
          |> Enum.uniq()

        put_change(changeset, :permissions, cleaned)
    end
  end
end
