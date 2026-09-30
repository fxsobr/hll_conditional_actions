defmodule HllConditionalActions.Rules.Condition do
  @moduledoc """
  One comparison inside a rule: `field operator value`.

  The value is stored as text and cast at evaluation time against the field's
  declared type (see `HllConditionalActions.Rules.Catalog.field_type/1`). That
  keeps the rule builder simple - every input is a text or select box - while
  the engine still compares numbers as numbers.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias HllConditionalActions.Rules.Catalog

  @type t :: %__MODULE__{}

  @primary_key false
  embedded_schema do
    field :field, Ecto.Enum, values: Catalog.fields(), default: :always_true
    field :operator, Ecto.Enum, values: Catalog.operators(), default: :equal
    field :value, :string, default: ""
    # Which group of the rule this condition belongs to, and that group's
    # "all / any / none". A rule with a single group ignores the operator;
    # see `HllConditionalActions.Rules.ConditionGroups`.
    field :group, :integer, default: 0
    field :group_operator, Ecto.Enum, values: Catalog.logical_operators()
    # Text the builder's regex tester runs the pattern against; never stored.
    field :sample, :string, virtual: true
  end

  @doc """
  Builds a changeset for a condition.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(condition, attrs) do
    condition
    |> cast(attrs, [:field, :operator, :value, :sample, :group, :group_operator])
    |> validate_required([:field, :operator])
    |> validate_number(:group, greater_than_or_equal_to: 0)
    |> validate_operator_matches_field()
    |> validate_value()
  end

  @doc """
  Runs a `regex_match` pattern against sample text, the way the engine
  would: `{:ok, true | false}`, or `{:error, reason}` for a bad pattern.

      iex> alias HllConditionalActions.Rules.Condition
      iex> {Condition.test_regex("^ana", "ana b"), Condition.test_regex("(", "x")}
      {{:ok, true}, {:error, "missing closing parenthesis"}}
  """
  @spec test_regex(String.t() | nil, String.t() | nil) :: {:ok, boolean()} | {:error, String.t()}
  def test_regex(pattern, sample) do
    case Regex.compile(to_string(pattern)) do
      {:ok, regex} -> {:ok, Regex.match?(regex, to_string(sample))}
      {:error, {reason, _at}} -> {:error, to_string(reason)}
    end
  end

  defp validate_operator_matches_field(changeset) do
    field = get_field(changeset, :field)
    operator = get_field(changeset, :operator)

    if is_nil(field) or is_nil(operator) or operator in Catalog.operators_for_field(field) do
      changeset
    else
      add_error(changeset, :operator, "is not valid for this field")
    end
  end

  # `always_true` ignores its value entirely, every other field needs one.
  defp validate_value(changeset) do
    case get_field(changeset, :field) do
      nil -> changeset
      :always_true -> changeset
      field -> changeset |> validate_required([:value]) |> validate_value_type(field)
    end
  end

  defp validate_value_type(changeset, field) do
    operator = get_field(changeset, :operator)
    value = get_field(changeset, :value)

    cond do
      is_nil(value) or value == "" ->
        changeset

      operator == :regex_match ->
        validate_regex(changeset, value)

      Catalog.list_operator?(operator) ->
        validate_list(changeset, value, Catalog.field_type(field))

      true ->
        validate_scalar(changeset, value, Catalog.field_type(field))
    end
  end

  defp validate_regex(changeset, value) do
    case Regex.compile(value) do
      {:ok, _regex} ->
        changeset

      {:error, {reason, _at}} ->
        add_error(changeset, :value, "is not a valid regex: %{reason}", reason: to_string(reason))
    end
  end

  defp validate_list(changeset, value, type) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> add_error(changeset, :value, "must list at least one value")
      values -> Enum.reduce(values, changeset, &validate_scalar(&2, &1, type))
    end
  end

  defp validate_scalar(changeset, value, :integer) do
    case Integer.parse(value) do
      {_int, ""} -> changeset
      _other -> add_error(changeset, :value, "must be a whole number")
    end
  end

  defp validate_scalar(changeset, value, :float) do
    case Float.parse(value) do
      {_float, ""} -> changeset
      _other -> add_error(changeset, :value, "must be a number")
    end
  end

  defp validate_scalar(changeset, value, :boolean) do
    if String.downcase(value) in ~w(true false 1 0 yes no) do
      changeset
    else
      add_error(changeset, :value, "must be true or false")
    end
  end

  defp validate_scalar(changeset, _value, _type), do: changeset
end
