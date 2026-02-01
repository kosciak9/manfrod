defmodule Manfrod.Code do
  @moduledoc """
  Self-modification capabilities for Manfrod.

  Provides functions to list modules, read/write source files,
  compile code, and evaluate expressions. Manfrod uses this
  to modify himself.
  """

  # Repo root is determined at runtime, not compile time
  defp repo_root do
    Application.get_env(:manfrod, :repo_root) || File.cwd!()
  end

  @doc """
  List all loaded modules.

  Returns a list of all modules currently loaded in the BEAM.
  """
  @spec list() :: [module()]
  def list do
    :code.all_loaded()
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  @doc """
  List only Manfrod modules.

  Filters loaded modules to those starting with `Manfrod`.
  """
  @spec list_manfrod() :: [module()]
  def list_manfrod do
    list()
    |> Enum.filter(fn mod ->
      mod |> to_string() |> String.starts_with?("Elixir.Manfrod")
    end)
  end

  @doc """
  Get source code for a module.

  Reads the .ex file from disk for the given module.
  Returns `{:ok, source}` or `{:error, reason}`.
  """
  @spec source(module()) :: {:ok, String.t()} | {:error, atom()}
  def source(module) do
    case module_to_path(module) do
      {:ok, path} -> File.read(path)
      error -> error
    end
  end

  @doc """
  Write source code and hot-reload the module.

  Writes the source to the module's file and compiles it,
  replacing the running module in the BEAM.
  """
  @spec write(module(), String.t()) :: {:ok, module()} | {:error, String.t()}
  def write(module, source) do
    with {:ok, path} <- module_to_path(module),
         :ok <- File.write(path, source),
         {:ok, modules} <- compile_file(path) do
      {:ok, List.first(modules) || module}
    end
  end

  @doc """
  Create a new module file and compile it.

  Creates the file at the appropriate path based on module name,
  writes the source, and compiles it.
  """
  @spec create(module(), String.t()) :: {:ok, module()} | {:error, String.t()}
  def create(module, source) do
    path = module_to_new_path(module)
    dir = Path.dirname(path)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, source),
         {:ok, modules} <- compile_file(path) do
      {:ok, List.first(modules) || module}
    end
  end

  @doc """
  Evaluate an Elixir expression.

  Evaluates the code string and returns the result.
  """
  @spec eval(String.t()) :: {:ok, any()} | {:error, String.t()}
  def eval(code) do
    {result, _binding} = Code.eval_string(code)
    {:ok, result}
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end

  @doc """
  Get the file path for a module.
  """
  @spec path(module()) :: {:ok, String.t()} | {:error, :not_found}
  def path(module), do: module_to_path(module)

  @doc """
  Recompile all Manfrod modules from disk.
  """
  @spec recompile_all() :: :ok | {:error, String.t()}
  def recompile_all do
    lib_path = Path.join(repo_root(), "lib")

    Path.wildcard(Path.join(lib_path, "**/*.ex"))
    |> Enum.each(fn path ->
      case compile_file(path) do
        {:ok, _} -> :ok
        {:error, reason} -> IO.puts("Failed to compile #{path}: #{reason}")
      end
    end)

    :ok
  end

  # Private functions

  defp module_to_path(module) do
    # Manfrod.Agent -> lib/manfrod/agent.ex
    relative_path =
      module
      |> to_string()
      |> String.replace_prefix("Elixir.", "")
      |> Macro.underscore()
      |> Kernel.<>(".ex")

    path = Path.join([repo_root(), "lib", relative_path])

    if File.exists?(path) do
      {:ok, path}
    else
      {:error, :not_found}
    end
  end

  defp module_to_new_path(module) do
    relative_path =
      module
      |> to_string()
      |> String.replace_prefix("Elixir.", "")
      |> Macro.underscore()
      |> Kernel.<>(".ex")

    Path.join([repo_root(), "lib", relative_path])
  end

  defp compile_file(path) do
    modules = Code.compile_file(path)
    {:ok, Enum.map(modules, &elem(&1, 0))}
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end
end
