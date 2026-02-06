defmodule Manfrod.Workers.RetrospectionWorker do
  @moduledoc """
  Oban worker that triggers retrospection every hour.
  The actual work is delegated to the Retrospector agent.
  """
  use Oban.Worker,
    queue: :retrospection,
    max_attempts: 3

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.info("RetrospectionWorker: starting retrospection")

    case Manfrod.Memory.Retrospector.process_slipbox() do
      :ok ->
        Logger.info("RetrospectionWorker: retrospection completed")
        :ok

      {:error, reason} ->
        Logger.error("RetrospectionWorker: retrospection failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
