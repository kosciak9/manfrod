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
  alias Manfrod.Memory
  alias Manfrod.Memory.Soul
  alias Manfrod.Shell

  @base_url "https://opencode.ai/zen/v1"
  @model_id "kimi-k2.5-free"

  @system_prompt """
  Your capabilities:
  - list_modules: See all loaded Elixir modules
  - read_source: Read the source code of any module (including yourself)
  - write_source: Modify any module's source code and hot-reload it
  - create_module: Create entirely new modules
  - eval_code: Evaluate Elixir expressions
  - run_shell: Execute bash commands

  Use git for version control. Commit your changes with meaningful messages.
  If something breaks, you can rollback with git.
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

  # Server Callbacks

  # 60 minutes debounce before flushing conversation
  @flush_delay :timer.minutes(60)

  @impl true
  def init(_opts) do
    system_message = ReqLLM.Context.system(build_system_prompt())

    {:ok,
     %{
       messages: [system_message],
       flush_timer: nil
     }}
  end

  defp build_system_prompt do
    if Memory.has_soul?() do
      @system_prompt
    else
      @system_prompt <> Soul.base_prompt()
    end
  end

  @impl true
  def handle_cast({:message, message}, state) do
    %{content: content, source: source, reply_to: reply_to} = message
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Logger.info("Agent received message from #{source}: #{String.slice(content, 0, 50)}...")

    # Persist user message to DB
    {:ok, _user_msg} =
      Memory.create_message(%{
        role: "user",
        content: content,
        received_at: now
      })

    # Build event context for broadcasts
    event_ctx = %{source: source, reply_to: reply_to}

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

  # Private

  defp process_message(text, state, event_ctx) do
    # Retrieve relevant memory context
    memory_context = get_memory_context(text)

    # Build user message with memory context prepended
    user_content =
      if memory_context == "" do
        text
      else
        "[Memory context]\n#{memory_context}\n\n[User message]\n#{text}"
      end

    user_message = ReqLLM.Context.user(user_content)
    messages = state.messages ++ [user_message]

    # Call LLM with tools, handle tool loop
    case call_llm_with_tools(messages, event_ctx) do
      {:ok, response_text, _final_messages} ->
        # Store original user message (without memory) for clean history
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

  defp call_llm_with_tools(messages, event_ctx, iteration \\ 0) do
    # Prevent infinite tool loops
    if iteration > 10 do
      {:error, :max_tool_iterations}
    else
      case call_llm(messages) do
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
              call_llm_with_tools(messages_with_results, event_ctx, iteration + 1)

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

  defp get_memory_context(query) do
    soul = Memory.get_soul()

    relevant =
      case Memory.search(query, limit: 5) do
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

  defp call_llm(messages) do
    call_llm_with_retry(messages, _retries = 5, _delay = 2000)
  end

  defp call_llm_with_retry(_messages, 0, _delay) do
    {:error, :max_retries_exceeded}
  end

  defp call_llm_with_retry(messages, retries, delay) do
    api_key = Application.get_env(:manfrod, :zen_api_key)
    context = ReqLLM.Context.new(messages)
    model = %{id: @model_id, provider: :openai}

    opts = [
      base_url: @base_url,
      api_key: api_key,
      tools: tools()
    ]

    case ReqLLM.generate_text(model, context, opts) do
      {:ok, response} ->
        {:ok, response}

      {:error, %{status: status}} when status in [429, 500, 502, 503] ->
        Logger.warning("LLM rate limited or server error (#{status}), retrying in #{delay}ms...")
        Process.sleep(delay)
        call_llm_with_retry(messages, retries - 1, delay * 2)

      {:error, _} = error ->
        error
    end
  end
end
