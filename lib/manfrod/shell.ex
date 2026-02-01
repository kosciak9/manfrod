defmodule Manfrod.Shell do
  @moduledoc """
  Shell access for Manfrod.

  Provides the ability to execute arbitrary bash commands.
  This is the ultimate interface - Manfrod can do anything
  the system allows: git, apt, curl, etc.
  """

  @default_timeout 30_000

  @doc """
  Execute a bash command.

  Returns `{output, exit_code}` where output is the combined
  stdout and stderr.

  ## Examples

      iex> Manfrod.Shell.run("echo hello")
      {:ok, "hello\\n", 0}
      
      iex> Manfrod.Shell.run("ls /nonexistent")
      {:ok, "ls: cannot access '/nonexistent': No such file or directory\\n", 2}
  """
  @spec run(String.t()) :: {:ok, String.t(), integer()} | {:error, String.t()}
  def run(command) do
    run(command, timeout: @default_timeout)
  end

  @doc """
  Execute a bash command with options.

  ## Options

    * `:timeout` - Maximum time in milliseconds (default: 30_000)
    * `:cd` - Directory to run the command in
    * `:env` - Environment variables as a list of `{"KEY", "value"}` tuples

  ## Examples

      iex> Manfrod.Shell.run("pwd", cd: "/tmp")
      {:ok, "/tmp\\n", 0}
      
      iex> Manfrod.Shell.run("sleep 60", timeout: 1000)
      {:error, "Command timed out after 1000ms"}
  """
  @spec run(String.t(), keyword()) :: {:ok, String.t(), integer()} | {:error, String.t()}
  def run(command, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    cd = Keyword.get(opts, :cd)
    env = Keyword.get(opts, :env, [])

    port_opts = [:binary, :exit_status, :stderr_to_stdout]
    port_opts = if cd, do: [{:cd, cd} | port_opts], else: port_opts
    port_opts = if env != [], do: [{:env, env} | port_opts], else: port_opts

    port = Port.open({:spawn, "bash -c #{escape_command(command)}"}, port_opts)

    collect_output(port, "", timeout)
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Execute a command and stream output line by line to a callback.

  Useful for long-running commands where you want to see progress.
  """
  @spec stream(String.t(), (String.t() -> any()), keyword()) ::
          {:ok, integer()} | {:error, String.t()}
  def stream(command, callback, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    cd = Keyword.get(opts, :cd)
    env = Keyword.get(opts, :env, [])

    port_opts = [:binary, :exit_status, {:line, 1024}]
    port_opts = if cd, do: [{:cd, cd} | port_opts], else: port_opts
    port_opts = if env != [], do: [{:env, env} | port_opts], else: port_opts

    port = Port.open({:spawn, "bash -c #{escape_command(command)}"}, port_opts)

    stream_loop(port, callback, timeout)
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Private functions

  defp collect_output(port, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        collect_output(port, acc <> data, timeout)

      {^port, {:exit_status, status}} ->
        {:ok, acc, status}
    after
      timeout ->
        Port.close(port)
        {:error, "Command timed out after #{timeout}ms"}
    end
  end

  defp stream_loop(port, callback, timeout) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        callback.(line)
        stream_loop(port, callback, timeout)

      {^port, {:data, {:noeol, line}}} ->
        callback.(line)
        stream_loop(port, callback, timeout)

      {^port, {:exit_status, status}} ->
        {:ok, status}
    after
      timeout ->
        Port.close(port)
        {:error, "Command timed out"}
    end
  end

  defp escape_command(command) do
    # Wrap in single quotes, escaping any single quotes in the command
    escaped = String.replace(command, "'", "'\"'\"'")
    "'#{escaped}'"
  end
end
