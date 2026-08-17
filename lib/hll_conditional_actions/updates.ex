defmodule HllConditionalActions.Updates do
  @moduledoc """
  Which version is running, and whether GitHub has a newer one.

  The releases are fetched on a timer rather than when somebody opens the
  About dialog: GitHub allows sixty unauthenticated requests an hour per IP,
  and a page that fetched on render would spend them on people clicking
  around. The answer lives in `:persistent_term`, so reading it costs a map
  lookup and the sidebar can ask on every render.

  A failed check is not an error worth surfacing anywhere but the dialog. The
  app does not need GitHub to run, so a rate limit, an outage or a server with
  no outbound access all end the same way: the last known answer stays, and
  the dialog says when it was last reached.
  """

  use GenServer

  require Logger

  @key {__MODULE__, :status}

  # Long enough that a restart loop cannot spend the hourly allowance, short
  # enough that a release published in the morning is noticed the same day.
  @interval_ms :timer.hours(6)

  # Let the app finish starting before reaching for the network.
  @initial_delay_ms :timer.seconds(30)

  @doc """
  The version this build reports.

  `BUILD_VERSION` is stamped in by the Docker build from `git describe`, so a
  deployed image says exactly which commit it is — `v0.1.0-10-g5982d51`. Built
  any other way, it falls back to the version in `mix.exs`.
  """
  def current_version do
    case System.get_env("BUILD_VERSION") do
      nil -> fallback_version()
      "" -> fallback_version()
      stamped -> stamped
    end
  end

  @doc """
  What the last check found. Never blocks and never raises.
  """
  def status do
    :persistent_term.get(@key, empty_status())
  end

  @doc """
  Check GitHub now. Returns immediately; the result lands in `status/0`.
  """
  def refresh do
    GenServer.cast(__MODULE__, :refresh)
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    :persistent_term.put(@key, empty_status())
    Process.send_after(self(), :check, @initial_delay_ms)

    {:ok, %{}}
  end

  @impl GenServer
  def handle_cast(:refresh, state) do
    check()

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:check, state) do
    check()
    Process.send_after(self(), :check, @interval_ms)

    {:noreply, state}
  end

  defp check do
    previous = status()

    case fetch_releases() do
      {:ok, releases} ->
        :persistent_term.put(@key, %{
          previous
          | releases: releases,
            latest: List.first(releases),
            update_available?: update_available?(current_version(), List.first(releases)),
            checked_at: DateTime.utc_now(),
            error: nil
        })

      {:error, reason} ->
        Logger.info("could not read the releases from GitHub: #{inspect(reason)}")

        :persistent_term.put(@key, %{previous | checked_at: DateTime.utc_now(), error: reason})
    end
  end

  @doc """
  Read the published releases, newest first.

  Drafts and pre-releases are dropped: neither is something an operator should
  be told to upgrade to.
  """
  def fetch_releases do
    request =
      Req.new(
        base_url: "https://api.github.com",
        url: "/repos/#{repository()}/releases",
        params: [per_page: 10],
        headers: [
          accept: "application/vnd.github+json",
          # GitHub rejects a request with no user agent.
          user_agent: "hll_conditional_actions"
        ],
        receive_timeout: :timer.seconds(10)
      )

    case Req.get(request, req_options()) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        {:ok, body |> Enum.reject(&(&1["draft"] || &1["prerelease"])) |> Enum.map(&release/1)}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp release(payload) do
    %{
      tag: payload["tag_name"],
      name: payload["name"] || payload["tag_name"],
      notes: payload["body"] || "",
      url: payload["html_url"],
      published_at: parse_time(payload["published_at"])
    }
  end

  defp parse_time(nil), do: nil

  defp parse_time(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _unparseable -> nil
    end
  end

  @doc """
  Whether `latest` is a release newer than the running version.

  Both sides are reduced to their `MAJOR.MINOR.PATCH`, so the commits-since
  suffix `git describe` adds does not make `v0.1.0-10-g5982d51` look like
  something other than `0.1.0`. Anything that does not parse — a version
  reported as a bare commit hash, a tag that is not semantic — means no
  comparison and therefore no claim that an update exists.
  """
  def update_available?(_current, nil), do: false

  def update_available?(current, %{tag: tag}) do
    with {:ok, running} <- semantic(current),
         {:ok, published} <- semantic(tag) do
      Version.compare(published, running) == :gt
    else
      :error -> false
    end
  end

  defp semantic(nil), do: :error

  defp semantic(value) do
    case Regex.run(~r/^v?(\d+\.\d+\.\d+)/, value) do
      [_whole, version] -> Version.parse(version)
      nil -> :error
    end
  end

  defp empty_status do
    %{
      releases: [],
      latest: nil,
      update_available?: false,
      checked_at: nil,
      error: nil
    }
  end

  defp fallback_version, do: "v" <> to_string(Application.spec(:hll_conditional_actions, :vsn))

  defp repository do
    Application.get_env(:hll_conditional_actions, :updates, [])
    |> Keyword.get(:repository, "fxsobr/hll_conditional_actions")
  end

  # Lets the tests answer for GitHub without reaching it.
  defp req_options do
    Application.get_env(:hll_conditional_actions, :updates_req_options, [])
  end
end
