defmodule Manfrod.Deployment do
  @moduledoc """
  Deployment utilities for self-update capabilities.

  Provides health checks and deployment state management.
  The actual update flow is handled by scripts/update.sh.
  """

  alias Manfrod.Repo

  @doc """
  Check if the database is healthy and accepting queries.

  Returns `true` if a simple SELECT succeeds, `false` otherwise.
  Used to detect broken migrations or DB connectivity issues.
  """
  @spec db_healthy?() :: boolean()
  def db_healthy? do
    case Ecto.Adapters.SQL.query(Repo, "SELECT 1", [], timeout: 5_000) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @doc """
  Mark that an update is in progress. Called by update.sh before restart.
  Stores the new commit SHA.
  """
  @spec mark_updating(String.t()) :: :ok
  def mark_updating(commit_sha) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.query!(
      """
      INSERT INTO deployment_state (key, value, updated_at)
      VALUES ('updating', $1, $2)
      ON CONFLICT (key) DO UPDATE SET value = $1, updated_at = $2
      """,
      [commit_sha, now]
    )

    :ok
  end

  @doc """
  Check if we just restarted after an update.
  Returns `{:ok, commit_sha}` if updating, `:none` otherwise.
  """
  @spec check_updating() :: {:ok, String.t()} | :none
  def check_updating do
    case Repo.query("SELECT value FROM deployment_state WHERE key = 'updating'", []) do
      {:ok, %{rows: [[sha]]}} -> {:ok, sha}
      _ -> :none
    end
  end

  @doc """
  Clear the updating flag. Called after agent has acknowledged the update.
  """
  @spec clear_updating() :: :ok
  def clear_updating do
    Repo.query!("DELETE FROM deployment_state WHERE key = 'updating'", [])
    :ok
  end
end
