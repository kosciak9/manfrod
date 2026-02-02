defmodule Manfrod.Deployment do
  @moduledoc """
  Deployment utilities for self-update capabilities.

  Provides health checks and deployment state management.
  The actual update flow is handled by scripts/update.sh.
  """

  @doc """
  Check if the database is healthy and accepting queries.

  Returns `true` if a simple SELECT succeeds, `false` otherwise.
  Used to detect broken migrations or DB connectivity issues.
  """
  @spec db_healthy?() :: boolean()
  def db_healthy? do
    case Ecto.Adapters.SQL.query(Manfrod.Repo, "SELECT 1", [], timeout: 5_000) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end
end
