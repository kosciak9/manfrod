defmodule Manfrod.Builder do
  @moduledoc """
  Builder agent - improves the codebase.

  Runs periodically (every 3 hours) and operates in one of two modes:
  - **Task mode**: If there's a pending task, execute it
  - **Exploration mode**: If no tasks, introspect and discover improvements

  Builder has full code modification capabilities: read/write source,
  create modules, run shell commands, and execute Elixir code.
  """

  require Logger

  alias Manfrod.Agent.Init
  alias Manfrod.Code
  alias Manfrod.Events
  alias Manfrod.LLM
  alias Manfrod.Memory
  alias Manfrod.Shell
  alias Manfrod.Tasks
  alias Manfrod.Voyage

  @task_mode_prompt """
  You are Builder, the code improvement agent for Manfrod.

  You have ONE task to complete this session. Focus entirely on this task.

  ## Your task
  %{task_description}

  ## Your capabilities
  - list_modules: See all Elixir modules
  - read_source: Read any module's source code
  - write_source: Modify and hot-reload modules
  - create_module: Create new modules
  - eval_code: Evaluate Elixir expressions
  - run_shell: Execute bash commands (git, mix, etc.)
  - search_notes: Search the knowledge graph
  - get_note: Fetch a specific note
  - create_note: Create a note (for documenting work)
  - link_notes: Link related notes
  - complete_task: Mark your current task as done (REQUIRED when finished)

  ## Workflow
  1. Understand the task fully
  2. Read relevant source code
  3. Make changes incrementally
  4. Test: run `mix compile --warnings-as-errors && mix format --check-formatted`
  5. Commit with meaningful message
  6. Call complete_task with a summary of what you did

  ## Additional instructions
  - Your branch is `local-customisations`
  - Commit atomic changes
  - Run compile + format check after changes
  - Sometimes you can improve the system by adding good notes and extending the
    environment (e.g. install a CLI tool and adding instructions on how to use
    it). Research before commiting to either approach.

  When done, you MUST call complete_task. Say "Done." after calling it.
  """

  @exploration_mode_prompt """
  You are Builder, the code improvement agent for Manfrod.

  No tasks are queued for you. This is an EXPLORATION session.

  ## Your mission
  Introspect the system. Look for improvements. Create tasks for your future self.

  ## What to explore
  - Review recent events: errors, retries, slow operations
  - Explore the codebase: look for patterns, tech debt, opportunities
  - Check git log: understand recent changes
  - Look at random graph nodes: find interesting connections

  ## Your capabilities
  - list_modules: See all Elixir modules
  - read_source: Read any module's source code
  - write_source: Modify and hot-reload modules (use sparingly in exploration)
  - create_module: Create new modules
  - eval_code: Evaluate Elixir expressions
  - run_shell: Execute bash commands
  - search_notes: Search the knowledge graph
  - get_note: Fetch a specific note
  - create_note: Create a note (for observations, tasks)
  - link_notes: Link related notes
  - create_task: Create a task for your future self

  ## Workflow
  1. Review the context provided (events, git log, graph sample)
  2. Pick something interesting to explore
  3. Investigate deeply
  4. Document findings as notes
  5. Create tasks for improvements you discover

  ## Output
  Create a session log note summarizing:
  - What you explored
  - What you learned
  - Tasks you created (if any)
  - Any changes you made

  When done, say "Done."
  """

  # Tools available to Builder
  defp tools(current_task_id) do
    base_tools() ++ task_tools(current_task_id)
  end

  defp base_tools do
    [
      ReqLLM.Tool.new!(
        name: "list_modules",
        description: "List all Manfrod Elixir modules.",
        parameter_schema: [],
        callback: &tool_list_modules/1
      ),
      ReqLLM.Tool.new!(
        name: "read_source",
        description: "Read the source code of an Elixir module.",
        parameter_schema: [
          module: [type: :string, required: true, doc: "Module name, e.g., 'Manfrod.Agent'"]
        ],
        callback: &tool_read_source/1
      ),
      ReqLLM.Tool.new!(
        name: "write_source",
        description: "Write new source code for a module and hot-reload it.",
        parameter_schema: [
          module: [type: :string, required: true, doc: "Module name"],
          source: [type: :string, required: true, doc: "Complete Elixir source code"]
        ],
        callback: &tool_write_source/1
      ),
      ReqLLM.Tool.new!(
        name: "create_module",
        description: "Create a new Elixir module.",
        parameter_schema: [
          module: [type: :string, required: true, doc: "Module name"],
          source: [type: :string, required: true, doc: "Complete Elixir source code"]
        ],
        callback: &tool_create_module/1
      ),
      ReqLLM.Tool.new!(
        name: "eval_code",
        description: "Evaluate an Elixir expression and return the result.",
        parameter_schema: [
          code: [type: :string, required: true, doc: "Elixir expression to evaluate"]
        ],
        callback: &tool_eval_code/1
      ),
      ReqLLM.Tool.new!(
        name: "run_shell",
        description: "Execute a bash command.",
        parameter_schema: [
          command: [type: :string, required: true, doc: "Bash command to execute"],
          timeout: [type: :integer, doc: "Timeout in milliseconds (default: 30000)"]
        ],
        callback: &tool_run_shell/1
      ),
      ReqLLM.Tool.new!(
        name: "search_notes",
        description: "Search the knowledge graph for relevant notes.",
        parameter_schema: [
          query: [type: :string, required: true, doc: "Search query"]
        ],
        callback: &tool_search_notes/1
      ),
      ReqLLM.Tool.new!(
        name: "get_note",
        description: "Fetch a specific note by UUID, including linked notes.",
        parameter_schema: [
          id: [type: :string, required: true, doc: "Note UUID"]
        ],
        callback: &tool_get_note/1
      ),
      ReqLLM.Tool.new!(
        name: "create_note",
        description: "Create a new note in the knowledge graph.",
        parameter_schema: [
          content: [type: :string, required: true, doc: "The note content"]
        ],
        callback: &tool_create_note/1
      ),
      ReqLLM.Tool.new!(
        name: "link_notes",
        description: "Create a link between two notes.",
        parameter_schema: [
          note_a_id: [type: :string, required: true, doc: "First note UUID"],
          note_b_id: [type: :string, required: true, doc: "Second note UUID"]
        ],
        callback: &tool_link_notes/1
      )
    ]
  end

  defp task_tools(nil) do
    # Exploration mode: can create tasks
    [
      ReqLLM.Tool.new!(
        name: "create_task",
        description: "Create a task for your future self.",
        parameter_schema: [
          description: [type: :string, required: true, doc: "What needs to be done"]
        ],
        callback: &tool_create_task/1
      )
    ]
  end

  defp task_tools(task_id) do
    # Task mode: can complete current task
    [
      ReqLLM.Tool.new!(
        name: "complete_task",
        description: "Mark your current task as done. REQUIRED when finished.",
        parameter_schema: [
          output: [type: :string, required: true, doc: "Summary of what you did"]
        ],
        callback: fn args -> tool_complete_task(Map.put(args, :task_id, task_id)) end
      )
    ]
  end

  # Tool implementations

  def tool_list_modules(_args) do
    modules = Code.list_manfrod()
    {:ok, "Manfrod modules (#{length(modules)}):\n#{Enum.join(modules, "\n")}"}
  end

  def tool_read_source(%{module: module_name}) do
    module = String.to_atom("Elixir.#{module_name}")

    case Code.source(module) do
      {:ok, source} -> {:ok, source}
      {:error, :not_found} -> {:ok, "Module #{module_name} source not found"}
      {:error, reason} -> {:ok, "Error: #{inspect(reason)}"}
    end
  end

  def tool_write_source(%{module: module_name, source: source}) do
    module = String.to_atom("Elixir.#{module_name}")

    case Code.write(module, source) do
      {:ok, ^module} -> {:ok, "Successfully updated and reloaded #{module_name}"}
      {:ok, actual} -> {:ok, "Updated module (compiled as #{actual})"}
      {:error, reason} -> {:ok, "Compilation error: #{reason}"}
    end
  end

  def tool_create_module(%{module: module_name, source: source}) do
    module = String.to_atom("Elixir.#{module_name}")

    case Code.create(module, source) do
      {:ok, ^module} -> {:ok, "Successfully created #{module_name}"}
      {:ok, actual} -> {:ok, "Created module (compiled as #{actual})"}
      {:error, reason} -> {:ok, "Error: #{reason}"}
    end
  end

  def tool_eval_code(%{code: code}) do
    case Code.eval(code) do
      {:ok, result} -> {:ok, "Result: #{inspect(result, pretty: true, limit: 50)}"}
      {:error, reason} -> {:ok, "Error: #{reason}"}
    end
  end

  def tool_run_shell(%{command: command} = args) do
    timeout = Map.get(args, :timeout, 30_000)

    case Shell.run(command, timeout: timeout) do
      {:ok, output, 0} -> {:ok, "Exit 0:\n#{output}"}
      {:ok, output, code} -> {:ok, "Exit #{code}:\n#{output}"}
      {:error, reason} -> {:ok, "Shell error: #{reason}"}
    end
  end

  def tool_search_notes(%{query: query}) do
    {:ok, nodes} = Memory.search(query, limit: 10)

    if Enum.empty?(nodes) do
      {:ok, "No notes found for: #{query}"}
    else
      lines = Enum.map(nodes, fn n -> "- [#{n.id}] #{n.content}" end)
      {:ok, "Found #{length(nodes)} notes:\n#{Enum.join(lines, "\n")}"}
    end
  end

  def tool_get_note(%{id: id}) do
    case Memory.get_node(id) do
      nil ->
        {:ok, "Note not found: #{id}"}

      node ->
        linked = Memory.get_node_links(node.id)

        linked_text =
          if Enum.empty?(linked) do
            "No linked notes."
          else
            lines = Enum.map(linked, fn n -> "- [#{n.id}] #{n.content}" end)
            "Linked notes:\n#{Enum.join(lines, "\n")}"
          end

        {:ok, "Note [#{node.id}]:\n#{node.content}\n\n#{linked_text}"}
    end
  end

  def tool_create_note(%{content: content}) do
    case Voyage.embed_query(content) do
      {:ok, embedding} ->
        case Memory.create_node(%{content: content, embedding: embedding}) do
          {:ok, node} -> {:ok, "Created note: #{node.id}"}
          {:error, changeset} -> {:ok, "Failed: #{inspect(changeset.errors)}"}
        end

      {:error, reason} ->
        {:ok, "Failed to generate embedding: #{inspect(reason)}"}
    end
  end

  def tool_link_notes(%{note_a_id: a, note_b_id: b}) do
    case Memory.create_link(a, b) do
      {:ok, _link} -> {:ok, "Linked #{a} <-> #{b}"}
      {:error, changeset} -> {:ok, "Failed: #{inspect(changeset.errors)}"}
    end
  end

  def tool_create_task(%{description: description}) do
    # Create a note for the task description
    case Voyage.embed_query(description) do
      {:ok, embedding} ->
        case Memory.create_node(%{content: description, embedding: embedding}) do
          {:ok, note} ->
            # Create the task pointing to this note
            case Tasks.create(%{assignee: "builder", note_id: note.id}) do
              {:ok, task} ->
                {:ok, "Created task #{task.id} for future execution"}

              {:error, changeset} ->
                {:ok, "Failed to create task: #{inspect(changeset.errors)}"}
            end

          {:error, changeset} ->
            {:ok, "Failed to create note: #{inspect(changeset.errors)}"}
        end

      {:error, reason} ->
        {:ok, "Failed to generate embedding: #{inspect(reason)}"}
    end
  end

  def tool_complete_task(%{task_id: task_id, output: output}) do
    case Tasks.complete(task_id, output) do
      {:ok, _task} -> {:ok, "Task marked as done."}
      {:error, :not_found} -> {:ok, "Task not found: #{task_id}"}
      {:error, changeset} -> {:ok, "Failed: #{inspect(changeset.errors)}"}
    end
  end

  # Public API

  @doc """
  Run the Builder agent.

  Checks for pending tasks. If found, executes in task mode.
  Otherwise, runs in exploration mode.

  Returns :ok or {:error, reason}.
  """
  def run do
    Logger.info("Builder: starting run")

    Events.broadcast(:builder_started, %{
      source: :builder,
      meta: %{}
    })

    # Check for pending task
    case Tasks.get_next("builder") do
      nil ->
        run_exploration_mode()

      task ->
        run_task_mode(task)
    end
  end

  defp run_task_mode(task) do
    Logger.info("Builder: task mode - executing task #{task.id}")

    Events.broadcast(:builder_mode_selected, %{
      source: :builder,
      meta: %{mode: :task, task_id: task.id}
    })

    # Full context from Init + task mode capabilities
    base_context = Init.build_system_prompt(since: last_run_timestamp())

    capabilities =
      String.replace(@task_mode_prompt, "%{task_description}", task.note.content)

    system_prompt = base_context <> "\n\n" <> capabilities

    messages = [
      ReqLLM.Context.system(system_prompt)
    ]

    case run_agent_loop(messages, task.id) do
      {:ok, _final_text} ->
        Logger.info("Builder: task mode completed")

        Events.broadcast(:builder_completed, %{
          source: :builder,
          meta: %{mode: :task, task_id: task.id}
        })

        :ok

      {:error, reason} = err ->
        Logger.error("Builder: task mode failed: #{inspect(reason)}")

        Events.broadcast(:builder_failed, %{
          source: :builder,
          meta: %{mode: :task, task_id: task.id, reason: inspect(reason)}
        })

        err
    end
  end

  defp run_exploration_mode do
    Logger.info("Builder: exploration mode")

    Events.broadcast(:builder_mode_selected, %{
      source: :builder,
      meta: %{mode: :exploration}
    })

    # Full context from Init + exploration mode capabilities
    base_context = Init.build_system_prompt(since: last_run_timestamp())
    system_prompt = base_context <> "\n\n" <> @exploration_mode_prompt

    messages = [
      ReqLLM.Context.system(system_prompt)
    ]

    case run_agent_loop(messages, nil) do
      {:ok, _final_text} ->
        Logger.info("Builder: exploration mode completed")

        Events.broadcast(:builder_completed, %{
          source: :builder,
          meta: %{mode: :exploration}
        })

        :ok

      {:error, reason} = err ->
        Logger.error("Builder: exploration mode failed: #{inspect(reason)}")

        Events.broadcast(:builder_failed, %{
          source: :builder,
          meta: %{mode: :exploration, reason: inspect(reason)}
        })

        err
    end
  end

  defp run_agent_loop(messages, current_task_id, iteration \\ 0) do
    if iteration > 100 do
      {:error, :max_iterations}
    else
      case LLM.generate_text(messages, tools: tools(current_task_id), purpose: :builder) do
        {:ok, response} ->
          case ReqLLM.Response.finish_reason(response) do
            :tool_calls ->
              tool_calls = ReqLLM.Response.tool_calls(response)
              narrative = ReqLLM.Response.text(response) || ""

              Logger.debug("Builder: executing #{length(tool_calls)} tool(s)")

              assistant_msg = ReqLLM.Context.assistant(narrative, tool_calls: tool_calls)
              messages_with_assistant = messages ++ [assistant_msg]

              messages_with_results =
                Enum.reduce(tool_calls, messages_with_assistant, fn tool_call, msgs ->
                  result = execute_tool(tool_call, current_task_id)

                  tool_result_msg =
                    ReqLLM.Context.tool_result(tool_call.id, tool_call.function.name, result)

                  msgs ++ [tool_result_msg]
                end)

              run_agent_loop(messages_with_results, current_task_id, iteration + 1)

            _other ->
              text = ReqLLM.Response.text(response) || ""
              {:ok, text}
          end

        {:error, _} = err ->
          err
      end
    end
  end

  defp execute_tool(tool_call, current_task_id) do
    tool_name = tool_call.function.name
    args_json = tool_call.function.arguments

    case Jason.decode(args_json) do
      {:ok, args} ->
        tool = Enum.find(tools(current_task_id), &(&1.name == tool_name))

        if tool do
          case ReqLLM.Tool.execute(tool, args) do
            {:ok, result} -> result
            {:error, reason} -> "Tool error: #{inspect(reason)}"
          end
        else
          "Unknown tool: #{tool_name}"
        end

      {:error, _} ->
        "Failed to parse tool arguments"
    end
  end

  defp last_run_timestamp do
    # Get timestamp of last builder_started event, or default to 3 hours ago
    # For now, just use 3 hours ago as default
    DateTime.utc_now()
    |> DateTime.add(-3, :hour)
  end
end
