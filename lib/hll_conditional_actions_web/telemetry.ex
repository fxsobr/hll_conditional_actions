defmodule HllConditionalActionsWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://telemetry-metrics.hexdocs.pm
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Rule engine
      counter("hll_conditional_actions.rule.fired.count",
        tags: [:server_id, :status],
        description: "Rules that fired, by outcome"
      ),
      summary("hll_conditional_actions.rule.fired.duration",
        tags: [:server_id],
        unit: {:native, :millisecond},
        description: "How long a rule takes from decision to its actions finishing"
      ),
      counter("hll_conditional_actions.rule.skipped.count",
        tags: [:server_id, :reason],
        description: "Rules that matched a trigger but did not run (cooldown, conditions, caps)"
      ),

      # CRCON API. Latency here is the first place a struggling game server or
      # a saturated CRCON shows up.
      summary("hll_conditional_actions.crcon.request.stop.duration",
        tags: [:endpoint, :outcome],
        unit: {:native, :millisecond},
        description: "CRCON API round trip"
      ),
      counter("hll_conditional_actions.crcon.request.stop.duration",
        tags: [:endpoint, :outcome],
        description: "CRCON API calls, by endpoint and outcome"
      ),
      counter("hll_conditional_actions.crcon.request.exception.duration",
        tags: [:endpoint],
        description: "CRCON API calls that raised"
      ),

      # Log stream
      counter("hll_conditional_actions.log_stream.event.count",
        tags: [:server_id, :type],
        description: "Game events received, by kind"
      ),
      counter("hll_conditional_actions.log_stream.status.count",
        tags: [:server_id, :status],
        description: "Log stream connection state changes"
      ),

      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("hll_conditional_actions.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("hll_conditional_actions.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("hll_conditional_actions.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("hll_conditional_actions.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("hll_conditional_actions.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {HllConditionalActionsWeb, :count_users, []}
    ]
  end
end
