defmodule HllConditionalActionsWeb.HealthController do
  @moduledoc """
  Liveness and readiness probes for Docker and any orchestrator in front of it.

    * `GET /health` - the web process is up
    * `GET /health/ready` - the database answers, so the app can actually serve
      traffic; used as the compose healthcheck before dependents start
  """

  use HllConditionalActionsWeb, :controller

  alias HllConditionalActions.Repo

  def index(conn, _params) do
    json(conn, %{status: "ok", version: version()})
  end

  def ready(conn, _params) do
    case Ecto.Adapters.SQL.query(Repo, "SELECT 1", []) do
      {:ok, _result} ->
        json(conn, %{status: "ok", database: "ok"})

      {:error, error} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{status: "error", database: Exception.message(error)})
    end
  end

  defp version do
    case Application.spec(:hll_conditional_actions, :vsn) do
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
  end
end
