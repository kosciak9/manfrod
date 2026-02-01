defmodule ManfrodWeb.HealthController do
  use ManfrodWeb, :controller

  def index(conn, _params) do
    health = %{
      status: "ok",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      services: %{
        agent: check_agent(),
        database: check_database()
      }
    }

    status_code =
      if health.services.agent == "ok" and health.services.database == "ok", do: 200, else: 503

    conn
    |> put_status(status_code)
    |> json(health)
  end

  defp check_agent do
    if Process.whereis(Manfrod.Agent), do: "ok", else: "down"
  end

  defp check_database do
    case Ecto.Adapters.SQL.query(Manfrod.Repo, "SELECT 1", []) do
      {:ok, _} -> "ok"
      {:error, _} -> "down"
    end
  rescue
    _ -> "down"
  end
end
