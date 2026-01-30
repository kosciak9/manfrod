defmodule Manfred.Agent do
  @moduledoc """
  The Agent - a GenServer with tools and a loop.
  Receives messages, thinks, acts, responds.
  """
  use GenServer

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
    {:ok, %{}}
  end

  @impl true
  def handle_call({:message, text}, _from, state) do
    response = process_message(text)
    {:reply, {:response, response}, state}
  end

  # Private

  defp process_message(text) do
    # For now, just echo back
    # Later: call LLM, execute tools, etc.
    "Received: #{text}"
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
