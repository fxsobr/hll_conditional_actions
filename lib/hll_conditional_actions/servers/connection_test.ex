defmodule HllConditionalActions.Servers.ConnectionTest do
  @moduledoc """
  The "Testar conexão" panel of the server form: everything worth knowing
  about an address and an API key before they are saved.

    * `run/1` - the key's permissions (`Servers.check_connection/1`), how
      long CRCON took to answer them, and which CRCON version it runs;
    * `probe_stream/2` - whether the log stream answers: a short lived
      `LogStream` under a throwaway id connects with the same key, counts the
      events CRCON replays from its buffer and is stopped. Its events go to
      its own PubSub topic, which nothing else listens to, so the engine
      never sees them twice.

  `review/2` sorts the permission review into what the panel lists:
  permissions the key lacks, each with what needs it, and the ones it has
  but nothing here uses.
  """

  alias HllConditionalActions.Crcon
  alias HllConditionalActions.Crcon.LogStream
  alias HllConditionalActions.Crcon.Permissions
  alias HllConditionalActions.Servers
  alias HllConditionalActions.Servers.Server

  @probe_ms 4_000

  @type result :: %{
          info: map(),
          latency_ms: non_neg_integer(),
          version: String.t() | nil,
          tested_at: DateTime.t()
        }

  @doc """
  Checks the key and reads the version. Same errors as
  `Servers.check_connection/1`.
  """
  @spec run(map()) :: {:ok, result()} | {:error, term()}
  def run(attrs) do
    {micros, result} = :timer.tc(fn -> Servers.check_connection(attrs) end)

    with {:ok, info} <- result do
      {:ok,
       %{
         info: info,
         latency_ms: div(micros, 1000),
         version: version(attrs),
         tested_at: DateTime.utc_now()
       }}
    end
  end

  defp version(attrs) do
    case Crcon.get_version(conn(attrs)) do
      {:ok, version} when is_binary(version) -> version
      {:ok, %{"version" => version}} when is_binary(version) -> version
      _other -> nil
    end
  end

  defp conn(attrs) do
    %{
      base_url: attrs |> fetch(:base_url) |> String.trim_trailing("/"),
      api_key: fetch(attrs, :api_key)
    }
  end

  defp fetch(attrs, key),
    do: attrs |> Map.get(to_string(key), Map.get(attrs, key)) |> to_string() |> String.trim()

  @doc """
  Opens the log stream for a moment and counts what arrives.

  Returns `{:ok, events}` once the stream connected (events may be 0), or
  `{:error, reason}` when it refused or never answered.
  """
  @spec probe_stream(map(), non_neg_integer()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def probe_stream(attrs, wait_ms \\ @probe_ms) do
    id = "probe-" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
    %{base_url: base_url, api_key: api_key} = conn(attrs)
    server = %Server{id: id, name: id, base_url: base_url, api_key: api_key}

    :ok = LogStream.subscribe(id)
    Phoenix.PubSub.subscribe(HllConditionalActions.PubSub, LogStream.status_topic())

    {:ok, pid} = GenServer.start(LogStream, server: server)

    deadline = System.monotonic_time(:millisecond) + wait_ms

    try do
      collect(id, deadline, %{connected?: false, events: 0, error: nil})
    after
      GenServer.stop(pid, :normal, 1_000)
      LogStream.unsubscribe(id)
      Phoenix.PubSub.unsubscribe(HllConditionalActions.PubSub, LogStream.status_topic())
      flush(id)
    end
  catch
    :exit, reason -> {:error, inspect(reason)}
  end

  defp collect(id, deadline, acc) do
    left = deadline - System.monotonic_time(:millisecond)

    receive do
      {:crcon_event, _event} ->
        collect(id, deadline, %{acc | events: acc.events + 1, connected?: true})

      {:crcon_stream_status, ^id, :connected} ->
        collect(id, deadline, %{acc | connected?: true})

      {:crcon_stream_status, ^id, {:error, reason}} ->
        if acc.connected?, do: done(acc), else: {:error, to_string(reason)}

      {:crcon_stream_status, ^id, _other} ->
        collect(id, deadline, acc)
    after
      max(left, 0) -> done(acc)
    end
  end

  defp done(%{connected?: true, events: events}), do: {:ok, events}
  defp done(_acc), do: {:error, "the log stream did not answer"}

  defp flush(id) do
    receive do
      {:crcon_event, _event} -> flush(id)
      {:crcon_stream_status, ^id, _status} -> flush(id)
    after
      0 -> :ok
    end
  end

  @doc """
  The review, sorted for the panel.

  `modules` is the set of modules the server has installed (empty for a new
  server): the VIP shop's reads only count as missing when it is installed.
  """
  @spec review(map(), MapSet.t()) :: %{
          fine: non_neg_integer(),
          missing: [{String.t(), atom()}],
          excess: [String.t()],
          to_review: non_neg_integer()
        }
  def review(permissions, modules) do
    granted = permissions.granted

    missing =
      Enum.map(permissions.missing_required, &{&1, :rules}) ++
        Enum.map(permissions.missing_reads, &{&1, :rules}) ++
        if MapSet.member?(modules, :vip_shop),
          do: Enum.map(["can_add_vip" | Permissions.shop()] -- granted, &{&1, :vip_shop}),
          else: []

    excess = permissions.excess

    %{
      fine: length(granted -- excess),
      missing: Enum.uniq_by(missing, &elem(&1, 0)),
      excess: excess,
      to_review: length(Enum.uniq_by(missing, &elem(&1, 0))) + length(excess)
    }
  end
end
