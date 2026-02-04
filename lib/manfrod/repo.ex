defmodule Manfrod.Repo do
  use Ecto.Repo,
    otp_app: :manfrod,
    adapter: Ecto.Adapters.Postgres

  @doc """
  Check if the database is healthy and accepting queries.

  Returns `true` if a simple SELECT succeeds, `false` otherwise.
  Used to detect broken migrations or DB connectivity issues.
  """
  @spec healthy?() :: boolean()
  def healthy? do
    case Ecto.Adapters.SQL.query(__MODULE__, "SELECT 1", [], timeout: 5_000) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end
end
