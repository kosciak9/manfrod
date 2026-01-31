defmodule Manfrod.Memory do
  @moduledoc """
  Slipbox-style memory: nodes + undirected links.
  Hybrid retrieval via pgvector (semantic) + ParadeDB BM25 (keyword).
  """

  import Ecto.Query
  import Pgvector.Ecto.Query
  import Paradex

  alias Manfrod.Repo
  alias Manfrod.Memory.{Node, Link}

  # --- Nodes ---

  def create_node(attrs) do
    %Node{}
    |> Node.changeset(attrs)
    |> Repo.insert()
  end

  def list_nodes(user_id, opts \\ []) do
    Node
    |> where([n], n.user_id == ^user_id)
    |> order_by([n], desc: n.inserted_at)
    |> limit(^Keyword.get(opts, :limit, 100))
    |> Repo.all()
  end

  # --- Links ---

  def create_link(node_a_id, node_b_id) do
    %Link{}
    |> Link.changeset(%{node_a_id: node_a_id, node_b_id: node_b_id})
    |> Repo.insert(on_conflict: :nothing)
  end

  # --- Hybrid Search ---

  @doc """
  Hybrid retrieval: vector + BM25 in parallel, then expand 1-hop links.
  """
  def search(query_text, user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    with {:ok, embedding} <- Manfrod.Voyage.embed_query(query_text) do
      [vector_results, bm25_results] =
        Task.await_many(
          [
            Task.async(fn -> vector_search(embedding, user_id, limit) end),
            Task.async(fn -> bm25_search(query_text, user_id, limit) end)
          ],
          :infinity
        )

      merged =
        (vector_results ++ bm25_results)
        |> Enum.uniq_by(& &1.id)
        |> Enum.take(limit)

      {:ok, expand_with_links(merged, limit * 2)}
    end
  end

  defp vector_search(embedding, user_id, limit) do
    vec = Pgvector.new(embedding)

    Node
    |> where([n], n.user_id == ^user_id and not is_nil(n.embedding))
    |> order_by([n], cosine_distance(n.embedding, ^vec))
    |> limit(^limit)
    |> Repo.all()
  end

  defp bm25_search(query_text, user_id, limit) do
    from(n in Node,
      select: {n, score(n.id)},
      where: n.user_id == ^user_id and n.id ~> match("content", ^query_text),
      order_by: [desc: score()],
      limit: ^limit
    )
    |> Repo.all()
    |> Enum.map(fn {node, _score} -> node end)
  end

  defp expand_with_links([], _max), do: []

  defp expand_with_links(nodes, max) do
    ids = Enum.map(nodes, & &1.id)

    linked =
      from(n in Node,
        join: l in Link,
        on:
          (l.node_a_id in ^ids and l.node_b_id == n.id) or
            (l.node_b_id in ^ids and l.node_a_id == n.id),
        distinct: n.id
      )
      |> Repo.all()

    (nodes ++ linked)
    |> Enum.uniq_by(& &1.id)
    |> Enum.take(max)
  end

  # --- Context Building ---

  def build_context([]), do: ""

  def build_context(nodes) do
    items = Enum.map_join(nodes, "\n- ", & &1.content)
    "Relevant memories:\n- #{items}"
  end
end
