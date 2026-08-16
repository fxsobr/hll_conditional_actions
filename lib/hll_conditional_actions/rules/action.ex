defmodule HllConditionalActions.Rules.Action do
  @moduledoc """
  Something a rule does once its conditions hold.

  Parameters are stored as a string-keyed map because they differ per action
  type; `HllConditionalActions.Rules.Catalog.action_params/1` declares the
  shape and this changeset enforces it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias HllConditionalActions.Rules.Catalog

  @type t :: %__MODULE__{}

  @primary_key false
  embedded_schema do
    field :type, Ecto.Enum, values: Catalog.action_types(), default: :message_player
    field :parameters, :map, default: %{}
  end

  @doc """
  Builds a changeset for an action.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(action, attrs) do
    action
    |> cast(attrs, [:type, :parameters])
    |> validate_required([:type])
    |> normalize_parameters()
    |> validate_parameters()
  end

  @doc """
  Fetches a parameter, falling back to the catalog default.

      iex> alias HllConditionalActions.Rules.Action
      iex> action = %Action{type: :temp_ban_player, parameters: %{"reason" => "Cheating"}}
      iex> {Action.param(action, :reason), Action.param(action, :duration_hours)}
      {"Cheating", 2}
  """
  @spec param(t(), atom()) :: term()
  def param(%__MODULE__{type: type, parameters: parameters}, key) do
    case Map.fetch(parameters, to_string(key)) do
      {:ok, value} -> value
      :error -> default_for(type, key)
    end
  end

  defp default_for(type, key) do
    Enum.find_value(Catalog.action_params(type), fn
      {^key, _param_type, opts} -> opts[:default]
      _other -> nil
    end)
  end

  # Keep only the parameters the action actually declares, so switching an
  # action's type in the builder does not carry stale keys along.
  defp normalize_parameters(changeset) do
    case get_field(changeset, :type) do
      nil ->
        changeset

      type ->
        allowed =
          type |> Catalog.action_params() |> Enum.map(fn {key, _, _} -> to_string(key) end)

        parameters =
          changeset
          |> get_field(:parameters, %{})
          |> Map.new(fn {key, value} -> {to_string(key), value} end)
          |> Map.take(allowed)

        put_change(changeset, :parameters, parameters)
    end
  end

  defp validate_parameters(changeset) do
    case get_field(changeset, :type) do
      nil ->
        changeset

      type ->
        parameters = get_field(changeset, :parameters, %{})

        Enum.reduce(Catalog.action_params(type), changeset, fn {key, param_type, opts}, acc ->
          validate_parameter(acc, parameters, key, param_type, opts)
        end)
    end
  end

  defp validate_parameter(changeset, parameters, key, param_type, opts) do
    value = Map.get(parameters, to_string(key))

    cond do
      blank?(value) and opts[:required] ->
        add_error(changeset, :parameters, "#{key} is required")

      blank?(value) ->
        changeset

      param_type == :integer ->
        validate_integer(changeset, key, value, opts[:min])

      param_type == :string and key == :webhook_url ->
        validate_webhook_url(changeset, value)

      true ->
        changeset
    end
  end

  defp validate_integer(changeset, key, value, min) do
    case cast_integer(value) do
      {:ok, int} when is_integer(min) and int < min ->
        add_error(changeset, :parameters, "#{key} must be at least #{min}")

      {:ok, _int} ->
        changeset

      :error ->
        add_error(changeset, :parameters, "#{key} must be a whole number")
    end
  end

  defp validate_webhook_url(changeset, value) do
    case URI.parse(to_string(value)) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        changeset

      _invalid ->
        add_error(changeset, :parameters, "webhook_url must be a full URL")
    end
  end

  defp cast_integer(value) when is_integer(value), do: {:ok, value}

  defp cast_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> {:ok, int}
      _other -> :error
    end
  end

  defp cast_integer(_value), do: :error

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end
