defmodule Manfrod.Tasks do
  @moduledoc """
  Context for managing agent tasks.

  Tasks are work items queued for agents (like Builder) to execute.
  Each task points to a note containing the description and optionally
  to the conversation that spawned it.
  """

  import Ecto.Query

  alias Manfrod.Repo
  alias Manfrod.Tasks.Task

  @doc """
  Create a new task.

  ## Required attributes

    * `:assignee` - the agent responsible (e.g., "builder")
    * `:note_id` - UUID of the note containing task description

  ## Optional attributes

    * `:conversation_id` - UUID of the originating conversation
  """
  def create(attrs) do
    %Task{}
    |> Task.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Get the next task for an assignee (oldest :todo, FIFO).

  Returns the task with its note preloaded, or nil if no tasks.
  """
  def get_next(assignee) do
    Task
    |> where([t], t.status == :todo and t.assignee == ^assignee)
    |> order_by([t], asc: t.inserted_at)
    |> limit(1)
    |> preload(:note)
    |> Repo.one()
  end

  @doc """
  Complete a task with output.

  Sets status to :done, records output and completed_at timestamp.

  Accepts either a Task struct or a task ID (binary).
  """
  def complete(task_or_id, output)

  def complete(%Task{} = task, output) do
    task
    |> Task.complete_changeset(output)
    |> Repo.update()
  end

  def complete(task_id, output) when is_binary(task_id) do
    case get(task_id) do
      nil -> {:error, :not_found}
      task -> complete(task, output)
    end
  end

  @doc """
  Get a task by ID with note preloaded.
  """
  def get(id) do
    Task
    |> preload(:note)
    |> Repo.get(id)
  end

  @doc """
  List tasks for an assignee.

  ## Options

    * `:status` - filter by status (:todo, :done, or nil for all)
    * `:limit` - max results (default: 50)
  """
  def list(assignee, opts \\ []) do
    status = Keyword.get(opts, :status)
    limit = Keyword.get(opts, :limit, 50)

    query =
      Task
      |> where([t], t.assignee == ^assignee)
      |> order_by([t], desc: t.inserted_at)
      |> limit(^limit)
      |> preload(:note)

    query =
      if status do
        where(query, [t], t.status == ^status)
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Count pending tasks for an assignee.
  """
  def count_pending(assignee) do
    Task
    |> where([t], t.status == :todo and t.assignee == ^assignee)
    |> Repo.aggregate(:count)
  end
end
