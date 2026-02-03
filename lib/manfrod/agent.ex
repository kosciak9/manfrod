defmodule Manfrod.Agent do
  @moduledoc """
  The Agent - a GenServer with an inbox.
  Receives messages asynchronously, thinks, acts, responds via event bus.

  Manfrod can modify his own code, execute shell commands, and evaluate
  arbitrary Elixir expressions. He is self-improving and self-healing.

  ## Event-driven architecture

  The Agent broadcasts Activity events instead of calling handlers directly:
  - `:thinking` - message received, starting LLM call
  - `:narrating` - agent explaining what it's doing (text between tool calls)
  - `:action_started` - beginning action execution (tool name, args)
  - `:action_completed` - action finished (result, duration, success/fail)
  - `:responding` - final response ready
  - `:idle` - conversation timed out

  Subscribers (Telegram.ActivityHandler, Memory.FlushHandler, ActivityLive) handle
  these events appropriately for their context.

  ## Message persistence

  Messages are persisted to the database immediately on receive/response.
  On idle, the FlushHandler triggers extraction which fetches pending
  messages from DB, generates a summary, and extracts facts.
  """
  use GenServer

  require Logger

  alias Manfrod.Code
  alias Manfrod.Events
  alias Manfrod.LLM
  alias Manfrod.Memory
  alias Manfrod.Memory.Soul
  alias Manfrod.Shell
  alias Manfrod.Telegram.TypingRefresher

  @system_prompt """
  Your capabilities:
  - list_modules: See all loaded Elixir modules
  - read_source: Read the source code of any module (including yourself)
  - write_source: Modify any module's source code and hot-reload it
  - create_module: Create entirely new modules
  - eval_code: Evaluate Elixir expressions
  - run_shell: Execute bash commands
  - set_reminder: Schedule a reminder for yourself at a specific time
  - list_reminders: See all pending reminders you have scheduled
  - cancel_reminder: Cancel a pending reminder by its job ID
  - search_notes: Search your zettelkasten for relevant notes
  - get_note: Fetch a specific note by UUID, including linked notes
  - create_note: Add a new note to your slipbox (integrated during retrospection)
  - delete_note: Remove a note and all its links
  - link_notes: Connect two related notes
  - unlink_notes: Disconnect two notes

  Note context is injected with each message, showing relevant notes with
  their UUIDs. Use search_notes to find more, get_note to explore
  specific notes and their connections.

  Use git for version control. Commit your changes with meaningful messages.
  If something breaks, you can rollback with git. Your branch is
  `local-customisations`, you should commit to that branch and rebase it on
  top of the upstream `main` branch.

  Self-update (two-phase process):
  1. Run `./scripts/update.sh` - pulls code, compiles, runs migrations.
     If compilation fails, the script rolls back automatically.
     On success, it prints "Update compiled successfully" and the next step.
  2. Tell the user the update is ready, then run `sudo systemctl restart manfrod`.
     You will die and restart with the new code. Your conversation context
     will be restored from the database automatically.
  """

  # Tool definitions are created at runtime to avoid compile-time validation issues
  defp tools do
    [
      ReqLLM.Tool.new!(
        name: "list_modules",
        description: "List all loaded Elixir modules in the system. Returns module names.",
        parameter_schema: [
          filter: [type: :string, doc: "Optional filter - 'manfrod' to list only Manfrod modules"]
        ],
        callback: &tool_list_modules/1
      ),
      ReqLLM.Tool.new!(
        name: "read_source",
        description:
          "Read the source code of an Elixir module. Use this to understand how things work.",
        parameter_schema: [
          module: [type: :string, required: true, doc: "Module name, e.g., 'Manfrod.Agent'"]
        ],
        callback: &tool_read_source/1
      ),
      ReqLLM.Tool.new!(
        name: "write_source",
        description:
          "Write new source code for a module and hot-reload it. The module will be immediately updated in the running system.",
        parameter_schema: [
          module: [type: :string, required: true, doc: "Module name, e.g., 'Manfrod.Agent'"],
          source: [
            type: :string,
            required: true,
            doc: "Complete Elixir source code for the module"
          ]
        ],
        callback: &tool_write_source/1
      ),
      ReqLLM.Tool.new!(
        name: "create_module",
        description:
          "Create a new Elixir module. The file will be created and the module compiled.",
        parameter_schema: [
          module: [
            type: :string,
            required: true,
            doc: "Module name, e.g., 'Manfrod.Skills.Weather'"
          ],
          source: [
            type: :string,
            required: true,
            doc: "Complete Elixir source code for the module"
          ]
        ],
        callback: &tool_create_module/1
      ),
      ReqLLM.Tool.new!(
        name: "eval_code",
        description:
          "Evaluate an Elixir expression and return the result. Use for quick computations or inspecting state.",
        parameter_schema: [
          code: [type: :string, required: true, doc: "Elixir expression to evaluate"]
        ],
        callback: &tool_eval_code/1
      ),
      ReqLLM.Tool.new!(
        name: "run_shell",
        description:
          "Execute a bash command on the host system. Use for git, apt, file operations, etc.",
        parameter_schema: [
          command: [type: :string, required: true, doc: "Bash command to execute"],
          timeout: [type: :integer, doc: "Timeout in milliseconds (default: 30000)"]
        ],
        callback: &tool_run_shell/1
      ),
      ReqLLM.Tool.new!(
        name: "set_reminder",
        description:
          "Schedule a reminder for yourself at a specific time. You will receive the message as a new conversation.",
        parameter_schema: [
          message: [type: :string, required: true, doc: "What to remind yourself about"],
          at: [
            type: :string,
            required: true,
            doc: "When to trigger (ISO8601 UTC datetime, e.g., '2026-02-04T14:00:00Z')"
          ]
        ],
        callback: &tool_set_reminder/1
      ),
      ReqLLM.Tool.new!(
        name: "list_reminders",
        description: "List all pending reminders you have scheduled.",
        parameter_schema: [],
        callback: &tool_list_reminders/1
      ),
      ReqLLM.Tool.new!(
        name: "cancel_reminder",
        description: "Cancel a pending reminder by its job ID.",
        parameter_schema: [
          id: [type: :integer, required: true, doc: "The job ID of the reminder to cancel"]
        ],
        callback: &tool_cancel_reminder/1
      ),
      ReqLLM.Tool.new!(
        name: "search_notes",
        description:
          "Search your zettelkasten for relevant notes. Use this when you need to find facts, preferences, or context not in the initial note context.",
        parameter_schema: [
          query: [
            type: :string,
            required: true,
            doc: "Search query - what you want to find"
          ]
        ],
        callback: &tool_search_notes/1
      ),
      ReqLLM.Tool.new!(
        name: "get_note",
        description:
          "Fetch a specific note by its UUID. Also returns linked notes for context. Use when you have a note ID from the context and want more details or related notes.",
        parameter_schema: [
          id: [
            type: :string,
            required: true,
            doc: "UUID of the note to fetch (e.g., '550e8400-e29b-41d4-a716-446655440000')"
          ]
        ],
        callback: &tool_get_note/1
      ),
      ReqLLM.Tool.new!(
        name: "create_note",
        description:
          "Create a new note in your slipbox. The note will be integrated into your zettelkasten during the next retrospection cycle. Use for facts worth remembering.",
        parameter_schema: [
          content: [
            type: :string,
            required: true,
            doc: "The atomic idea or fact (1-2 sentences)"
          ]
        ],
        callback: &tool_create_note/1
      ),
      ReqLLM.Tool.new!(
        name: "delete_note",
        description:
          "Delete a note from your zettelkasten. All links to/from this note are automatically removed.",
        parameter_schema: [
          id: [
            type: :string,
            required: true,
            doc: "UUID of the note to delete"
          ]
        ],
        callback: &tool_delete_note/1
      ),
      ReqLLM.Tool.new!(
        name: "link_notes",
        description:
          "Create a link between two notes. Links are undirected - order doesn't matter.",
        parameter_schema: [
          note_a_id: [type: :string, required: true, doc: "First note UUID"],
          note_b_id: [type: :string, required: true, doc: "Second note UUID"]
        ],
        callback: &tool_link_notes/1
      ),
      ReqLLM.Tool.new!(
        name: "unlink_notes",
        description: "Remove a link between two notes.",
        parameter_schema: [
          note_a_id: [type: :string, required: true, doc: "First note UUID"],
          note_b_id: [type: :string, required: true, doc: "Second note UUID"]
        ],
        callback: &tool_unlink_notes/1
      )
    ]
  end

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Send a message to the agent asynchronously.

  The agent will process the message and broadcast Activity events.
  Subscribers handle response delivery based on the source.

  ## Required fields

  - `content` - the message text
  - `source` - origin atom (:telegram, :cron, :web, etc.)
  - `reply_to` - opaque reference for response routing (chat_id, pid, etc.)
  """
  def send_message(message) when is_map(message) do
    GenServer.cast(__MODULE__, {:message, message})
  end

  @doc """
  Manually trigger idle state (close conversation and extract memories).

  Used for the /idle command to let users explicitly end a conversation.
  """
  def trigger_idle(event_ctx) do
    GenServer.cast(__MODULE__, {:trigger_idle, event_ctx})
  end

  # Tool callbacks (called by ReqLLM when LLM invokes tools)

  def tool_list_modules(%{filter: "manfrod"}) do
    modules = Code.list_manfrod()
    {:ok, "Manfrod modules:\n#{Enum.join(modules, "\n")}"}
  end

  def tool_list_modules(_args) do
    modules = Code.list_manfrod()

    {:ok,
     "Manfrod modules (#{length(modules)}):\n#{Enum.join(modules, "\n")}\n\nUse filter: 'manfrod' for just Manfrod modules, or call without filter to see all #{length(Code.list())} modules."}
  end

  def tool_read_source(%{module: module_name}) do
    module = String.to_atom("Elixir.#{module_name}")

    case Code.source(module) do
      {:ok, source} -> {:ok, source}
      {:error, :not_found} -> {:ok, "Module #{module_name} source not found on disk"}
      {:error, reason} -> {:ok, "Error reading source: #{inspect(reason)}"}
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
      {:error, reason} -> {:ok, "Error creating module: #{reason}"}
    end
  end

  def tool_eval_code(%{code: code}) do
    case Code.eval(code) do
      {:ok, result} -> {:ok, "Result: #{inspect(result, pretty: true, limit: 50)}"}
      {:error, reason} -> {:ok, "Evaluation error: #{reason}"}
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

  def tool_set_reminder(%{message: message, at: at_string}) do
    alias Manfrod.Workers.TriggerWorker

    case DateTime.from_iso8601(at_string) do
      {:ok, scheduled_at, _offset} ->
        if DateTime.compare(scheduled_at, DateTime.utc_now()) == :gt do
          args = %{
            prompt: "[Reminder] #{message}",
            trigger_id: "reminder_#{:erlang.phash2({message, scheduled_at})}"
          }

          case TriggerWorker.new(args, scheduled_at: scheduled_at) |> Oban.insert() do
            {:ok, job} ->
              {:ok, "Reminder set (job ##{job.id}) for #{scheduled_at}: #{message}"}

            {:error, reason} ->
              {:ok, "Failed to set reminder: #{inspect(reason)}"}
          end
        else
          {:ok, "Cannot set reminder in the past. Provide a future datetime."}
        end

      {:error, _} ->
        {:ok, "Invalid datetime. Use ISO8601 UTC like '2026-02-04T14:00:00Z'"}
    end
  end

  def tool_list_reminders(_args) do
    import Ecto.Query

    jobs =
      Oban.Job
      |> where([j], j.worker == "Manfrod.Workers.TriggerWorker")
      |> where([j], j.state in ["scheduled", "available"])
      |> where([j], fragment("?->>'trigger_id' LIKE 'reminder_%'", j.args))
      |> order_by([j], asc: j.scheduled_at)
      |> Manfrod.Repo.all()

    if Enum.empty?(jobs) do
      {:ok, "No pending reminders."}
    else
      lines =
        Enum.map(jobs, fn job ->
          message = String.replace_prefix(job.args["prompt"], "[Reminder] ", "")
          "• ##{job.id} at #{job.scheduled_at}: #{message}"
        end)

      {:ok, "Pending reminders:\n#{Enum.join(lines, "\n")}"}
    end
  end

  def tool_cancel_reminder(%{id: job_id}) do
    # Oban.cancel_job/1 always returns :ok (idempotent)
    :ok = Oban.cancel_job(job_id)
    {:ok, "Reminder ##{job_id} cancelled."}
  end

  def tool_search_notes(%{query: query}) do
    {:ok, nodes} = Memory.search(query, limit: 10)

    if Enum.empty?(nodes) do
      {:ok, "No relevant notes found for: #{query}"}
    else
      lines =
        Enum.map(nodes, fn node ->
          linked = Memory.get_node_links(node.id)
          linked_ids = Enum.map(linked, & &1.id) |> Enum.join(", ")

          if linked_ids == "" do
            "- [#{node.id}] #{node.content}"
          else
            "- [#{node.id}] #{node.content}\n  Linked to: #{linked_ids}"
          end
        end)

      {:ok, "Found #{length(nodes)} notes:\n#{Enum.join(lines, "\n")}"}
    end
  end

  def tool_get_note(%{id: id}) do
    case Memory.get_node(id) do
      nil ->
        {:ok, "Note not found: #{id}"}

      node ->
        linked_nodes = Memory.get_node_links(node.id)

        linked_content =
          if Enum.empty?(linked_nodes) do
            "No linked notes."
          else
            lines =
              Enum.map(linked_nodes, fn n ->
                "- [#{n.id}] #{n.content}"
              end)

            "Linked notes:\n#{Enum.join(lines, "\n")}"
          end

        {:ok,
         """
         Note [#{node.id}]:
         #{node.content}

         #{linked_content}
         """}
    end
  end

  def tool_create_note(%{content: content}) do
    case Manfrod.Voyage.embed_query(content) do
      {:ok, embedding} ->
        # Create in slipbox (processed_at: nil) - Retrospector will integrate
        case Memory.create_node(%{content: content, embedding: embedding}) do
          {:ok, node} ->
            {:ok, "Created note in slipbox: #{node.id}"}

          {:error, changeset} ->
            {:ok, "Failed to create note: #{inspect(changeset.errors)}"}
        end

      {:error, reason} ->
        {:ok, "Failed to generate embedding: #{inspect(reason)}"}
    end
  end

  def tool_delete_note(%{id: id}) do
    case Memory.delete_node(id) do
      {:ok, _node} ->
        {:ok, "Deleted note: #{id}"}

      {:error, :not_found} ->
        {:ok, "Note not found: #{id}"}
    end
  end

  def tool_link_notes(%{note_a_id: a, note_b_id: b}) do
    case Memory.create_link(a, b) do
      {:ok, _link} ->
        {:ok, "Linked #{a} <-> #{b}"}

      {:error, changeset} ->
        {:ok, "Failed to create link: #{inspect(changeset.errors)}"}
    end
  end

  def tool_unlink_notes(%{note_a_id: a, note_b_id: b}) do
    case Memory.delete_link(a, b) do
      {:ok, _link} ->
        {:ok, "Unlinked #{a} <-> #{b}"}

      {:error, :not_found} ->
        {:ok, "Link not found: #{a} <-> #{b}"}
    end
  end

  # Server Callbacks

  # 60 minutes debounce before flushing conversation
  @flush_delay :timer.minutes(60)

  @impl true
  def init(_opts) do
    system_message = ReqLLM.Context.system(build_system_prompt())

    # Check if we just restarted after an update
    Process.send_after(self(), :check_post_update, 1_000)

    {:ok,
     %{
       messages: [system_message],
       flush_timer: nil
     }}
  end

  defp build_system_prompt do
    if Manfrod.Deployment.db_healthy?() and Memory.has_soul?() do
      @system_prompt
    else
      @system_prompt <> Soul.base_prompt()
    end
  end

  @impl true
  def handle_cast({:message, message}, state) do
    %{content: content, source: source, reply_to: reply_to} = message
    event_ctx = %{source: source, reply_to: reply_to}

    # Check DB health before processing - respond with error if down
    unless Manfrod.Deployment.db_healthy?() do
      Logger.error("Agent: database unavailable, cannot process message")

      Events.broadcast(
        :responding,
        Map.put(event_ctx, :meta, %{
          content: "Issues with database. Need manual intervention."
        })
      )

      {:noreply, state}
    else
      do_handle_message(content, event_ctx, state)
    end
  end

  def handle_cast({:trigger_idle, event_ctx}, state) do
    Logger.info("Manual idle triggered via /idle command")

    # Cancel any pending flush timer
    if state.flush_timer, do: Process.cancel_timer(state.flush_timer)

    # Broadcast idle event - FlushHandler will trigger extraction
    Events.broadcast(:idle, event_ctx)

    # Reset to fresh conversation state
    system_message = ReqLLM.Context.system(build_system_prompt())

    {:noreply,
     %{
       messages: [system_message],
       flush_timer: nil
     }}
  end

  defp do_handle_message(content, event_ctx, state) do
    %{source: source, reply_to: _reply_to} = event_ctx
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Logger.info("Agent received message from #{source}: #{String.slice(content, 0, 50)}...")

    # Persist user message to DB
    {:ok, _user_msg} =
      Memory.create_message(%{
        role: "user",
        content: content,
        received_at: now
      })

    # Broadcast thinking activity
    Events.broadcast(:thinking, event_ctx)

    # Process with memory context and tools
    {response_text, new_state} = process_message(content, state, event_ctx)

    # Persist assistant response to DB
    {:ok, _assistant_msg} =
      Memory.create_message(%{
        role: "assistant",
        content: response_text,
        received_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    # Broadcast response - handlers deliver to appropriate channel
    Events.broadcast(:responding, Map.put(event_ctx, :meta, %{content: response_text}))
    Logger.info("Agent broadcast response for #{source}")

    # Debounce: cancel old timer, start new one
    if state.flush_timer, do: Process.cancel_timer(state.flush_timer)
    timer_ref = Process.send_after(self(), {:flush, event_ctx}, @flush_delay)

    {:noreply, %{new_state | flush_timer: timer_ref}}
  end

  @impl true
  def handle_info(:check_post_update, state) do
    case Manfrod.Deployment.check_updating() do
      {:ok, commit_sha} ->
        Logger.info("Agent restarted after update to #{commit_sha}")
        handle_post_update(commit_sha, state)

      :none ->
        {:noreply, state}
    end
  end

  def handle_info({:flush, event_ctx}, _state) do
    Logger.info("Conversation idle timeout - triggering extraction")

    # Broadcast idle event - FlushHandler will trigger extraction
    # Extractor fetches pending messages from DB
    Events.broadcast(:idle, event_ctx)

    # Reset to fresh conversation state
    # Re-build system prompt (soul may have been created during this conversation)
    system_message = ReqLLM.Context.system(build_system_prompt())

    {:noreply,
     %{
       messages: [system_message],
       flush_timer: nil
     }}
  end

  defp handle_post_update(commit_sha, state) do
    # Restore pending messages from DB to LLM context
    pending = Memory.get_pending_messages()
    restored_messages = Enum.map(pending, &message_to_context/1)

    new_messages = state.messages ++ restored_messages

    # Clear the updating flag
    Manfrod.Deployment.clear_updating()

    # Notify via Telegram that we're back
    event_ctx = %{source: :telegram, reply_to: nil}

    update_notice =
      "I just updated to #{String.slice(commit_sha, 0, 7)}. " <>
        "Restored #{length(pending)} messages from our conversation."

    Events.broadcast(:responding, Map.put(event_ctx, :meta, %{content: update_notice}))

    {:noreply, %{state | messages: new_messages}}
  end

  defp message_to_context(%{role: "user", content: content}) do
    ReqLLM.Context.user(content)
  end

  defp message_to_context(%{role: "assistant", content: content}) do
    ReqLLM.Context.assistant(content)
  end

  # Private

  defp process_message(text, state, event_ctx) do
    # Retrieve relevant note context
    note_context = get_note_context(text)

    # Build user message with note context prepended
    user_content =
      if note_context == "" do
        text
      else
        "[Note context]\n#{note_context}\n\n[User message]\n#{text}"
      end

    user_message = ReqLLM.Context.user(user_content)
    messages = state.messages ++ [user_message]

    # Call LLM with tools, handle tool loop
    case call_llm_with_tools(messages, event_ctx) do
      {:ok, response_text, _final_messages} ->
        # Store original user message (without note context) for clean history
        clean_user_message = ReqLLM.Context.user(text)
        assistant_message = ReqLLM.Context.assistant(response_text)
        new_messages = state.messages ++ [clean_user_message, assistant_message]
        {response_text, %{state | messages: new_messages}}

      {:error, reason} ->
        error_text = "Sorry, I encountered an error: #{inspect(reason)}"
        Logger.error("LLM call failed: #{inspect(reason)}")
        {error_text, state}
    end
  end

  defp call_llm_with_tools(messages, event_ctx) do
    # Start typing refresher to keep Telegram indicator alive during LLM retries/fallbacks
    {:ok, refresher_pid} = TypingRefresher.start(event_ctx)

    try do
      do_call_llm_with_tools(messages, event_ctx, 0)
    after
      TypingRefresher.stop(refresher_pid)
    end
  end

  defp do_call_llm_with_tools(messages, event_ctx, iteration) do
    # Prevent infinite tool loops
    if iteration > 50 do
      {:error, :max_tool_iterations}
    else
      case LLM.generate_text(messages, tools: tools(), purpose: :agent) do
        {:ok, response} ->
          case ReqLLM.Response.finish_reason(response) do
            :tool_calls ->
              # Execute tools and continue conversation
              tool_calls = ReqLLM.Response.tool_calls(response)
              Logger.info("Agent executing #{length(tool_calls)} tool(s)")

              # Extract any narrative text the LLM sent alongside tool calls
              narrative_text = ReqLLM.Response.text(response) || ""

              if narrative_text != "" do
                Events.broadcast(:narrating, Map.put(event_ctx, :meta, %{text: narrative_text}))
              end

              # Add assistant message with tool calls (include narrative text)
              assistant_msg = ReqLLM.Context.assistant(narrative_text, tool_calls: tool_calls)
              messages_with_assistant = messages ++ [assistant_msg]

              # Execute each tool and add results
              messages_with_results =
                Enum.reduce(tool_calls, messages_with_assistant, fn tool_call, msgs ->
                  action_id = generate_action_id()
                  action_name = tool_call.function.name
                  args = tool_call.function.arguments

                  # Broadcast action started
                  Events.broadcast(
                    :action_started,
                    Map.put(event_ctx, :meta, %{
                      action_id: action_id,
                      action: action_name,
                      args: args
                    })
                  )

                  # Execute and time the action
                  {result, duration_ms, success} = timed_execute_tool(tool_call)

                  # Broadcast action completed
                  Events.broadcast(
                    :action_completed,
                    Map.put(event_ctx, :meta, %{
                      action_id: action_id,
                      action: action_name,
                      result: truncate_result(result),
                      duration_ms: duration_ms,
                      success: success
                    })
                  )

                  tool_result_msg =
                    ReqLLM.Context.tool_result(tool_call.id, action_name, result)

                  msgs ++ [tool_result_msg]
                end)

              # Continue the conversation
              do_call_llm_with_tools(messages_with_results, event_ctx, iteration + 1)

            _other ->
              # No more tools, return final text
              text = ReqLLM.Response.text(response) || ""
              {:ok, text, messages}
          end

        {:error, _} = error ->
          error
      end
    end
  end

  defp timed_execute_tool(tool_call) do
    start_time = System.monotonic_time(:millisecond)
    {result, success} = execute_tool(tool_call)
    end_time = System.monotonic_time(:millisecond)
    duration_ms = end_time - start_time

    {result, duration_ms, success}
  end

  defp execute_tool(tool_call) do
    tool_name = tool_call.function.name
    args_json = tool_call.function.arguments

    case Jason.decode(args_json) do
      {:ok, args} ->
        # Find and execute the tool
        tool = Enum.find(tools(), &(&1.name == tool_name))

        if tool do
          case ReqLLM.Tool.execute(tool, args) do
            {:ok, result} -> {result, true}
            {:error, reason} -> {"Tool error: #{inspect(reason)}", false}
          end
        else
          {"Unknown tool: #{tool_name}", false}
        end

      {:error, _} ->
        {"Failed to parse tool arguments", false}
    end
  end

  defp generate_action_id do
    Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp truncate_result(result) when byte_size(result) > 500 do
    String.slice(result, 0, 497) <> "..."
  end

  defp truncate_result(result), do: result

  defp get_note_context(query) do
    soul = Memory.get_soul()

    relevant =
      case Memory.search(query, limit: 10) do
        {:ok, nodes} -> nodes
        _ -> []
      end

    # Combine soul + relevant, deduplicated (soul may appear in search results)
    nodes =
      [soul | relevant]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.id)

    Memory.build_context(nodes)
  end
end
