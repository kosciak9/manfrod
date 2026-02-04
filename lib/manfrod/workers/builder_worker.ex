defmodule Manfrod.Workers.BuilderWorker do
  @moduledoc """
  Oban worker that triggers Builder every 3 hours.
  The actual work is delegated to the Builder agent.
  """
  use Oban.Worker,
    queue: :builder,
    max_attempts: 1,
    unique: [period: {3, :hours}, states: :incomplete]

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.info("BuilderWorker: starting builder run")

    case Manfrod.Builder.run() do
      :ok ->
        Logger.info("BuilderWorker: builder completed")
        :ok

      {:error, reason} ->
        Logger.error("BuilderWorker: builder failed: #{inspect(reason)}")
        # Don't retry - Builder runs every 3 hours anyway
        :ok
    end
  end
end
