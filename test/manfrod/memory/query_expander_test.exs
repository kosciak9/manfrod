defmodule Manfrod.Memory.QueryExpanderTest do
  use ExUnit.Case, async: false

  alias Manfrod.Memory.QueryExpander

  @moduletag :external_api

  describe "expand/1" do
    test "expands a simple query into multiple variations" do
      {:ok, queries} = QueryExpander.expand("what was that project we discussed?")

      assert is_list(queries)
      assert length(queries) >= 1
      assert length(queries) <= 3

      # All queries should be strings
      assert Enum.all?(queries, &is_binary/1)

      # Original query should be included (or a close variation)
      assert Enum.any?(queries, &String.contains?(&1, "project"))
    end

    test "always includes original query as first element" do
      original = "user preferences for dark mode"
      {:ok, queries} = QueryExpander.expand(original)

      # First query should be the original
      assert hd(queries) == original
    end

    test "handles short queries" do
      {:ok, queries} = QueryExpander.expand("hello")

      assert is_list(queries)
      assert length(queries) >= 1
    end

    test "handles queries with special characters" do
      {:ok, queries} = QueryExpander.expand("what's the user's email address?")

      assert is_list(queries)
      assert length(queries) >= 1
    end

    test "respects timeout option" do
      # Very short timeout should fail gracefully and return original
      {:ok, queries} = QueryExpander.expand("test query", timeout_ms: 1)

      # Should fallback to original query on timeout
      assert queries == ["test query"]
    end
  end
end
