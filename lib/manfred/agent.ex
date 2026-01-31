defmodule Manfred.Agent do
  @moduledoc """
  The Agent - a GenServer with tools and a loop.
  Receives messages, thinks, acts, responds.
  """
  use GenServer

  require Logger

  @base_url "https://opencode.ai/zen/v1"
  @model_id "kimi-k2.5-free"

  @system_prompt """
  You are Manfred, a helpful AI assistant. You are friendly, concise, and helpful.
  Answer questions directly and clearly.
  """

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Send a message to the agent and get a response"
  def message(text) do
    GenServer.call(__MODULE__, {:message, text}, :infinity)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    system_message = ReqLLM.Context.system(@system_prompt)
    {:ok, %{messages: [system_message]}}
  end

  @impl true
  def handle_call({:message, text}, _from, state) do
    {response, new_state} = process_message(text, state)
    {:reply, {:response, response}, new_state}
  end

  # Private

  defp process_message(text, state) do
    user_message = ReqLLM.Context.user(text)
    messages = state.messages ++ [user_message]

    case call_llm(messages) do
      {:ok, response_text} ->
        assistant_message = ReqLLM.Context.assistant(response_text)
        new_messages = messages ++ [assistant_message]
        {response_text, %{state | messages: new_messages}}

      {:error, reason} ->
        error_text = "Error: #{inspect(reason)}"
        Logger.error("LLM call failed: #{inspect(reason)}")
        {error_text, state}
    end
  end

  defp call_llm(messages) do
    call_llm_with_retry(messages, _retries = 3, _delay = 1000)
  end

  defp call_llm_with_retry(_messages, 0, _delay) do
    {:error, :max_retries_exceeded}
  end

  defp call_llm_with_retry(messages, retries, delay) do
    api_key = Application.get_env(:manfred, :zen_api_key)
    context = ReqLLM.Context.new(messages)
    model = %{id: @model_id, provider: :openai}

    case ReqLLM.generate_text(model, context, base_url: @base_url, api_key: api_key) do
      {:ok, response} ->
        {:ok, ReqLLM.Response.text(response)}

      {:error, %{status: status}} when status in [429, 500, 502, 503] ->
        Logger.warning("LLM rate limited or server error (#{status}), retrying in #{delay}ms...")
        Process.sleep(delay)
        call_llm_with_retry(messages, retries - 1, delay * 2)

      {:error, _} = error ->
        error
    end
  end

  # Tools

  @doc "Execute a bash command"
  def tool_bash(command) do
    case System.cmd("bash", ["-c", command], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, code, output}
    end
  end

  @doc "Read a file"
  def tool_read_file(path) do
    File.read(path)
  end

  @doc "Write a file"
  def tool_write_file(path, content) do
    File.write(path, content)
  end

  @doc "Compile and reload a module from file"
  def tool_reload_file(path) do
    try do
      Code.compile_file(path)
      :ok
    rescue
      e -> {:error, e}
    end
  end

  @doc "Reload a module by name"
  def tool_reload_module(module) when is_atom(module) do
    :code.purge(module)
    :code.load_file(module)
  end
end
