defmodule HllConditionalActions.Accounts.Permission do
  @moduledoc """
  The fixed set of permissions a role can grant.

  Permissions are code, not data: adding one means adding the check that
  enforces it, so there is no value in letting operators invent new names. Roles
  are data and simply hold a list of these.

  They come in view/manage pairs. `manage_*` implies `view_*` through
  `expand/1`, so a role that can manage servers never needs both listed.
  """

  @permissions [
    view_servers: :servers,
    manage_servers: :servers,
    view_rules: :rules,
    manage_rules: :rules,
    view_executions: :monitoring,
    view_live_feed: :monitoring,
    manage_users: :platform,
    manage_roles: :platform
  ]

  @groups [:servers, :rules, :monitoring, :platform]

  # manage_x grants view_x, so an "Operator" role only has to list what it can
  # change.
  @implications %{
    manage_servers: [:view_servers],
    manage_rules: [:view_rules],
    manage_users: [:manage_roles]
  }

  @doc """
  Every permission.
  """
  @spec all() :: [atom()]
  def all, do: Keyword.keys(@permissions)

  @doc """
  Every permission as a string, for storage and comparison.
  """
  @spec all_strings() :: [String.t()]
  def all_strings, do: Enum.map(all(), &to_string/1)

  @doc """
  Permission groups, in display order.
  """
  @spec groups() :: [atom()]
  def groups, do: @groups

  @doc """
  The group a permission belongs to.
  """
  @spec group(atom()) :: atom()
  def group(permission), do: Keyword.fetch!(@permissions, permission)

  @doc """
  Permissions in a group.
  """
  @spec in_group(atom()) :: [atom()]
  def in_group(group), do: for({permission, ^group} <- @permissions, do: permission)

  @doc """
  Whether a value names a permission.

      iex> alias HllConditionalActions.Accounts.Permission
      iex> {Permission.valid?("manage_rules"), Permission.valid?("launch_missiles")}
      {true, false}
  """
  @spec valid?(atom() | String.t()) :: boolean()
  def valid?(permission) when is_atom(permission), do: permission in all()
  def valid?(permission) when is_binary(permission), do: permission in all_strings()
  def valid?(_permission), do: false

  @doc """
  Expands a list of granted permissions with everything they imply.

      iex> HllConditionalActions.Accounts.Permission.expand(["manage_servers"])
      ["manage_servers", "view_servers"]
  """
  @spec expand([String.t()]) :: [String.t()]
  def expand(permissions) when is_list(permissions) do
    permissions
    |> Enum.flat_map(fn permission ->
      implied =
        @implications
        |> Map.get(safe_atom(permission), [])
        |> Enum.map(&to_string/1)

      [to_string(permission) | implied]
    end)
    |> Enum.uniq()
  end

  # Permissions arrive from the database and from forms, so never call
  # String.to_atom/1 on them; unknown names simply imply nothing.
  defp safe_atom(permission) when is_atom(permission), do: permission

  defp safe_atom(permission) when is_binary(permission) do
    Enum.find(all(), &(to_string(&1) == permission))
  end
end
