defmodule Manfrod.Agent do
  @moduledoc """
  The Agent - a GenServer with an inbox.
  Receives messages asynchronously, thinks, acts, responds via Telegram.
  """
  use GenServer

  require Logger

  alias Manfrod.Memory
  alias Manfrod.Memory.Extractor
  alias Manfrod.Telegram.Sender

  @base_url "https://opencode.ai/zen/v1"
  @model_id "kimi-k2.5-free"

  @system_prompt """
  You are Manfrod, a helpful AI assistant. You are friendly, concise, and helpful.
  Answer questions directly and clearly.
  """

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Send a message to the agent asynchronously.
  The agent will process and respond via Telegram.

  Message must include:
  - :content - the text content
  - :chat_id - Telegram chat ID for response
  - :source - origin of message (e.g., :telegram)
  """
  def send_message(message) when is_map(message) do
    GenServer.cast(__MODULE__, {:message, message})
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    system_message = ReqLLM.Context.system(@system_prompt)
    {:ok, %{messages: [system_message]}}
  end

  @impl true
  def handle_cast({:message, message}, state) do
    %{content: content, chat_id: chat_id, user_id: user_id} = message

    Logger.info(
      "Agent received message from #{message[:source]}: #{String.slice(content, 0, 50)}..."
    )

    # Process with memory context
    {response_text, new_state} = process_message(content, user_id, state)

    # Async extraction (parallel embedding + storage)
    Extractor.extract_async(content, response_text, user_id)

    case Sender.send(chat_id, response_text) do
      {:ok, _} ->
        Logger.info("Agent sent response to chat #{chat_id}")

      {:error, reason} ->
        Logger.error("Failed to send response to Telegram: #{inspect(reason)}")
    end

    {:noreply, new_state}
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

    case call_llm(messages) do
      {:ok, response_text} ->
        assistant_message = ReqLLM.Context.assistant(response_text)
        # Store original user message (without memory) for clean history
        clean_user_message = ReqLLM.Context.user(text)
        new_messages = state.messages ++ [clean_user_message, assistant_message]
        {response_text, %{state | messages: new_messages}}

      {:error, reason} ->
        error_text = "Sorry, I encountered an error. Please try again."
        Logger.error("LLM call failed: #{inspect(reason)}")
        {error_text, state}
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
end
