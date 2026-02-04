defmodule Manfrod.Tasks.Task do
  @moduledoc """
  A task for an agent to execute.

  Tasks are linked to notes (which contain the description) and optionally
  to conversations (for provenance tracking).

  ## Lifecycle

  1. Created with status `:todo` and an assignee (e.g., "builder")
  2. Agent picks up oldest `:todo` task (FIFO)
  3. Agent executes and sets status to `:done` with output and completed_at
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Manfrod.Memory.{Conversation, Node}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "tasks" do
    field :status, Ecto.Enum, values: [:todo, :done], default: :todo
    field :assignee, :string
    field :output, :string
    field :completed_at, :utc_datetime

    belongs_to :note, Node
    belongs_to :conversation, Conversation

    timestamps()
  end

  @doc """
  Changeset for creating a new task.
  """
  def changeset(task, attrs) do
    task
    |> cast(attrs, [:status, :assignee, :output, :completed_at, :note_id, :conversation_id])
    |> validate_required([:assignee, :note_id])
    |> foreign_key_constraint(:note_id)
    |> foreign_key_constraint(:conversation_id)
  end

  @doc """
  Changeset for completing a task.
  """
  def complete_changeset(task, output) do
    task
    |> change(%{
      status: :done,
      output: output,
      completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end
end
