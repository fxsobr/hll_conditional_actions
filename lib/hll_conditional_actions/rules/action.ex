defmodule HllConditionalActions.Rules.Action do
  @moduledoc """
  Something a rule does once its conditions hold.

  Parameters are stored as a string-keyed map because they differ per action
  type; `HllConditionalActions.Rules.Catalog.action_params/1` declares the
  shape and this changeset enforces it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias HllConditionalActions.Discord
  alias HllConditionalActions.Discord.Webhook
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
    |> validate_discord_body()
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
        add_error(changeset, :parameters, "%{param} is required", param: to_string(key))

      blank?(value) ->
        changeset

      true ->
        validate_value(changeset, key, param_type, value, opts)
    end
  end

  defp validate_value(changeset, key, :integer, value, opts),
    do: validate_integer(changeset, key, value, opts[:min])

  defp validate_value(changeset, key, :discord_webhook, value, _opts),
    do: validate_discord_webhook(changeset, key, value)

  defp validate_value(changeset, key, :select, value, opts),
    do: validate_select(changeset, key, value, opts[:options])

  defp validate_value(changeset, key, :color, value, _opts) do
    check(
      changeset,
      key,
      is_binary(value) and value =~ ~r/^#[0-9a-fA-F]{6}$/,
      "%{param} must be a colour like #5865F2"
    )
  end

  defp validate_value(changeset, key, :url, value, _opts) do
    check(changeset, key, Webhook.https?(value), "%{param} must be an https:// address")
  end

  defp validate_value(changeset, :thread_id, _type, value, _opts) do
    check(
      changeset,
      :thread_id,
      is_binary(value) and value =~ ~r/^\d+$/,
      "%{param} must be a Discord id"
    )
  end

  defp validate_value(changeset, _key, _type, _value, _opts), do: changeset

  defp check(changeset, _key, true, _message), do: changeset

  defp check(changeset, key, false, message),
    do: add_error(changeset, :parameters, message, param: to_string(key))

  defp validate_integer(changeset, key, value, min) do
    case cast_integer(value) do
      {:ok, int} when is_integer(min) and int < min ->
        add_error(changeset, :parameters, "%{param} must be at least %{min}",
          param: to_string(key),
          min: min
        )

      {:ok, _int} ->
        changeset

      :error ->
        add_error(changeset, :parameters, "%{param} must be a whole number",
          param: to_string(key)
        )
    end
  end

  defp validate_discord_webhook(changeset, key, value) do
    if Discord.get_webhook(value) do
      changeset
    else
      add_error(changeset, :parameters, "%{param} must be a registered Discord webhook",
        param: to_string(key)
      )
    end
  end

  defp validate_select(changeset, key, value, options) do
    if to_string(value) in options do
      changeset
    else
      add_error(changeset, :parameters, "%{param} is not one of the choices",
        param: to_string(key)
      )
    end
  end

  # A Discord message with neither text nor embed would be refused with a 400.
  @discord_body ~w(message embed_title embed_description embed_fields)

  defp validate_discord_body(changeset) do
    parameters = get_field(changeset, :parameters, %{})

    if get_field(changeset, :type) == :send_discord_webhook and
         Enum.all?(@discord_body, &blank?(parameters[&1])) do
      add_error(changeset, :parameters, "a Discord message needs a text or an embed")
    else
      changeset
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
