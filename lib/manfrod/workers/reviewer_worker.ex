defmodule Manfrod.Workers.ReviewerWorker do
  @moduledoc """
  Oban worker that triggers the Reviewer agent.

  Runs on cron schedule, offset from Builder so it reviews
  Builder's most recent changes. The actual work is delegated
  to the Reviewer agent.
  """
  use Oban.Worker,
    queue: :reviewer,
    max_attempts: 1,
    unique: [period: {1, :hour}, states: :incomplete]

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.info("ReviewerWorker: starting reviewer run")

    case Manfrod.Reviewer.run() do
      {:ok, outcome} ->
        Logger.info("ReviewerWorker: reviewer completed with outcome: #{outcome}")
        :ok

      {:error, reason} ->
        Logger.error("ReviewerWorker: reviewer failed: #{inspect(reason)}")
        # Don't retry - will run again on next cron cycle
        :ok
    end
  end
end
