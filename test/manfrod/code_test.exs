defmodule Manfrod.CodeTest do
  use ExUnit.Case, async: true

  alias Manfrod.Code

  @test_dir Path.join(
              System.tmp_dir!(),
              "manfrod_code_test_#{System.unique_integer([:positive])}"
            )

  setup_all do
    File.mkdir_p!(Path.join(@test_dir, "lib/manfrod"))
    original = Application.get_env(:manfrod, :repo_root)
    Application.put_env(:manfrod, :repo_root, @test_dir)

    on_exit(fn ->
      if original, do: Application.put_env(:manfrod, :repo_root, original)
      File.rm_rf!(@test_dir)
    end)

    :ok
  end

  describe "list/0" do
    test "returns sorted list of loaded modules" do
      modules = Code.list()
      assert is_list(modules)
      assert length(modules) > 0
      assert Enum.all?(modules, &is_atom/1)
      assert modules == Enum.sort(modules)
    end
  end

  describe "list_manfrod/0" do
    test "returns only Manfrod.* modules" do
      modules = Code.list_manfrod()
      assert Manfrod.Code in modules
      assert Manfrod.Application in modules

      for mod <- modules do
        assert mod |> to_string() |> String.starts_with?("Elixir.Manfrod")
      end
    end
  end

  describe "eval/1" do
    test "evaluates arithmetic" do
      assert {:ok, 42} = Code.eval("21 * 2")
    end

    test "evaluates function calls" do
      assert {:ok, 6} = Code.eval("Enum.sum([1, 2, 3])")
    end

    test "returns error on syntax error" do
      assert {:error, _} = Code.eval("1 +")
    end

    test "returns error on runtime error" do
      assert {:error, msg} = Code.eval("raise \"boom\"")
      assert msg =~ "boom"
    end
  end

  describe "create/2 and write/2" do
    test "creates and hot-reloads module" do
      id = System.unique_integer([:positive])
      mod = Module.concat(Manfrod, :"TestMod#{id}")

      source_v1 = """
      defmodule #{mod} do
        def value, do: 1
      end
      """

      assert {:ok, ^mod} = Code.create(mod, source_v1)
      assert apply(mod, :value, []) == 1

      source_v2 = """
      defmodule #{mod} do
        def value, do: 2
      end
      """

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert {:ok, ^mod} = Code.write(mod, source_v2)
      end)

      assert apply(mod, :value, []) == 2
    end
  end

  describe "source/1 and path/1" do
    test "reads source of created module" do
      id = System.unique_integer([:positive])
      mod = Module.concat(Manfrod, :"SourceTest#{id}")

      source = """
      defmodule #{mod} do
        def hello, do: :world
      end
      """

      {:ok, _} = Code.create(mod, source)

      assert {:ok, read_source} = Code.source(mod)
      assert read_source =~ "def hello"

      assert {:ok, path} = Code.path(mod)
      assert path =~ "source_test#{id}.ex"
    end

    test "returns error for missing module" do
      assert {:error, :not_found} = Code.source(Manfrod.DoesNotExist)
      assert {:error, :not_found} = Code.path(Manfrod.DoesNotExist)
    end
  end
end
