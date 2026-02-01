defmodule Manfrod.Agent do
  @moduledoc """
  The Agent - a GenServer with an inbox.
  Receives messages asynchronously, thinks, acts, responds via Telegram.

  Manfrod can modify his own code, execute shell commands, and evaluate
  arbitrary Elixir expressions. He is self-improving and self-healing.
  """
  use GenServer

  require Logger

  alias Manfrod.Code
  alias Manfrod.Shell
  alias Manfrod.Memory
  alias Manfrod.Memory.Extractor
  alias Manfrod.Telegram.Sender

  @base_url "https://opencode.ai/zen/v1"
  @model_id "kimi-k2.5-free"

  @system_prompt """
  You are Manfrod, a self-improving AI agent running on a Raspberry Pi.

  You have full access to your own source code and can modify yourself.
  You can execute any bash command on your host system.
  You can evaluate arbitrary Elixir code.

  Your capabilities:
  - list_modules: See all loaded Elixir modules
  - read_source: Read the source code of any module (including yourself)
  - write_source: Modify any module's source code and hot-reload it
  - create_module: Create entirely new modules
  - eval_code: Evaluate Elixir expressions
  - run_shell: Execute bash commands

  You are running on a Raspberry Pi which is your sandbox. You can break things,
  install packages, modify files - it's all part of learning and improving.

  Use git for version control. Commit your changes with meaningful messages.
  If something breaks, you can rollback with git.

  Be curious. Experiment. Improve yourself.
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
  The agent will process and respond via Telegram.
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

  # 5 minutes debounce before flushing conversation
  @flush_delay :timer.minutes(5)

  @impl true
  def init(_opts) do
    system_message = ReqLLM.Context.system(@system_prompt)

    {:ok,
     %{
       messages: [system_message],
       flush_buffer: [],
       flush_timer: nil
     }}
  end

  @impl true
  def handle_cast({:message, message}, state) do
    %{content: content, chat_id: chat_id, user_id: user_id} = message

    Logger.info(
      "Agent received message from #{message[:source]}: #{String.slice(content, 0, 50)}..."
    )

    # Process with memory context and tools
    {response_text, new_state} = process_message(content, user_id, state)

    case Sender.send(chat_id, response_text) do
      {:ok, _} ->
        Logger.info("Agent sent response to chat #{chat_id}")

      {:error, reason} ->
        Logger.error("Failed to send response to Telegram: #{inspect(reason)}")
    end

    # Buffer exchange for batch extraction
    new_buffer = new_state.flush_buffer ++ [{content, response_text}]

    # Debounce: cancel old timer, start new one
    if state.flush_timer, do: Process.cancel_timer(state.flush_timer)
    timer_ref = Process.send_after(self(), {:flush, user_id}, @flush_delay)

    {:noreply, %{new_state | flush_buffer: new_buffer, flush_timer: timer_ref}}
  end

  @impl true
  def handle_info({:flush, user_id}, state) do
    Logger.info("Flushing conversation buffer (#{length(state.flush_buffer)} exchanges)")

    if state.flush_buffer != [] do
      Extractor.extract_batch_async(state.flush_buffer, user_id)
    end

    # Reset to fresh conversation state
    system_message = ReqLLM.Context.system(@system_prompt)

    {:noreply,
     %{
       messages: [system_message],
       flush_buffer: [],
       flush_timer: nil
     }}
  end

  # Private

  defp process_message(text, user_id, state) do
    # Retrieve relevant memory context
    memory_context = get_memory_context(text, user_id)

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
    case call_llm_with_tools(messages) do
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

  defp call_llm_with_tools(messages, iteration \\ 0) do
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

              # Add assistant message with tool calls
              assistant_msg = ReqLLM.Context.assistant("", tool_calls: tool_calls)
              messages_with_assistant = messages ++ [assistant_msg]

              # Execute each tool and add results
              messages_with_results =
                Enum.reduce(tool_calls, messages_with_assistant, fn tool_call, msgs ->
                  result = execute_tool(tool_call)

                  tool_result_msg =
                    ReqLLM.Context.tool_result(tool_call.id, tool_call.function.name, result)

                  msgs ++ [tool_result_msg]
                end)

              # Continue the conversation
              call_llm_with_tools(messages_with_results, iteration + 1)

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

  defp execute_tool(tool_call) do
    tool_name = tool_call.function.name
    args_json = tool_call.function.arguments

    case Jason.decode(args_json) do
      {:ok, args} ->
        # Find and execute the tool
        tool = Enum.find(tools(), &(&1.name == tool_name))

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

  defp get_memory_context(query, user_id) do
    case Memory.search(query, user_id, limit: 5) do
      {:ok, nodes} when nodes != [] ->
        Memory.build_context(nodes)

      _ ->
        ""
    end
  end

  defp call_llm(messages) do
    call_llm_with_retry(messages, _retries = 3, _delay = 1000)
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
