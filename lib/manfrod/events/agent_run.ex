defmodule Manfrod.Events.AgentRun do
  @moduledoc """
  Represents a single run of the Retrospector agent.

  Derived from audit events - correlates start/complete/fail events into
  a coherent run with computed fields.

  ## Fields

  - `agent` - `:retrospector`
  - `started_at` - when the run began
  - `ended_at` - when the run ended (nil if still running)
  - `duration_ms` - computed duration in milliseconds (nil if still running)
  - `outcome` - `:success`, `:failure`, or `:running`
  - `intent` - what the agent intended to do (summary)
  - `stats` - outcome statistics from completed event meta
  """

  @type outcome :: :success | :failure | :running

  @type t :: %__MODULE__{
          agent: :retrospector,
          started_at: DateTime.t(),
          ended_at: DateTime.t() | nil,
          duration_ms: non_neg_integer() | nil,
          outcome: outcome(),
          intent: String.t(),
          stats: map()
        }

  @enforce_keys [:agent, :started_at, :outcome, :intent]
  defstruct [
    :agent,
    :started_at,
    :ended_at,
    :duration_ms,
    :outcome,
    :intent,
    :stats
  ]

  @doc """
  Create an AgentRun from a start event and optional end event.

  The start event must be a `retrospection_started` event.
  The end event (if provided) must be the corresponding completed/failed event.
  """
  def from_events(start_event, end_event \\ nil)

  def from_events(%{type: "retrospection_started"} = start, nil) do
    slipbox_count = start.meta["slipbox_count"] || 0
    review_count = start.meta["review_count"] || 0

    %__MODULE__{
      agent: :retrospector,
      started_at: start.timestamp,
      ended_at: nil,
      duration_ms: nil,
      outcome: :running,
      intent: "Process #{slipbox_count} slipbox nodes, review #{review_count} graph nodes",
      stats: %{}
    }
  end

  def from_events(%{type: "retrospection_started"} = start, end_event) do
    slipbox_count = start.meta["slipbox_count"] || 0
    review_count = start.meta["review_count"] || 0

    outcome =
      cond do
        String.ends_with?(end_event.type, "_completed") -> :success
        String.ends_with?(end_event.type, "_failed") -> :failure
        true -> :running
      end

    duration_ms = DateTime.diff(end_event.timestamp, start.timestamp, :millisecond)

    %__MODULE__{
      agent: :retrospector,
      started_at: start.timestamp,
      ended_at: end_event.timestamp,
      duration_ms: duration_ms,
      outcome: outcome,
      intent: "Process #{slipbox_count} slipbox nodes, review #{review_count} graph nodes",
      stats: end_event.meta || %{}
    }
  end
end
