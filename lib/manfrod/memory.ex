defmodule Manfrod.Memory do
  @moduledoc """
  Slipbox-style memory: nodes + undirected links.
  Hybrid retrieval via pgvector (semantic) + ParadeDB BM25 (keyword).

  Also manages conversations and messages for provenance tracking.

  All mutating operations emit events to the event bus for audit visibility.
  """

  import Ecto.Query
  import Pgvector.Ecto.Query
  import Paradex

  alias Manfrod.Events
  alias Manfrod.Repo
  alias Manfrod.Memory.{Conversation, Message, Node, Link}

  # --- Messages ---

  @doc """
  Create a pending message (conversation_id = nil).
  """
  def create_message(attrs) do
    %Message{}
    |> Message.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Get all pending messages (not yet assigned to a conversation).
  Ordered by received_at ascending.
  """
  def get_pending_messages do
    Message
    |> where([m], is_nil(m.conversation_id))
    |> order_by([m], asc: m.received_at)
    |> Repo.all()
  end

  # --- Conversations ---

  @doc """
  Close a conversation: create conversation record and link all pending messages.
  Returns {:ok, conversation} or {:error, changeset}.

  Expects attrs with :summary key. started_at and ended_at are computed from messages.
  """
  def close_conversation(attrs) do
    Repo.transaction(fn ->
      messages = get_pending_messages()

      if messages == [] do
        Repo.rollback(:no_pending_messages)
      end

      started_at = messages |> List.first() |> Map.get(:received_at)
      ended_at = messages |> List.last() |> Map.get(:received_at)

      conversation_attrs =
        attrs
        |> Map.put(:started_at, started_at)
        |> Map.put(:ended_at, ended_at)

      case %Conversation{} |> Conversation.changeset(conversation_attrs) |> Repo.insert() do
        {:ok, conversation} ->
          # Link all pending messages to this conversation
          message_ids = Enum.map(messages, & &1.id)

          {_count, _} =
            from(m in Message, where: m.id in ^message_ids)
            |> Repo.update_all(set: [conversation_id: conversation.id])

          conversation

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Get a conversation with its messages preloaded.
  """
  def get_conversation_with_messages(conversation_id) do
    Conversation
    |> where([c], c.id == ^conversation_id)
    |> preload(:messages)
    |> Repo.one()
  end

  # --- Soul ---

  @doc """
  Check if the zettelkasten has a soul (any nodes exist).
  """
  def has_soul? do
    Repo.exists?(Node)
  end

  @doc """
  Get the soul - the first node by insertion time.
  Returns nil if no nodes exist.
  """
  def get_soul do
    Node
    |> order_by([n], asc: n.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  # --- Nodes ---

  def create_node(attrs) do
    result =
      %Node{}
      |> Node.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, node} ->
        Events.broadcast(:memory_node_created, %{
          source: :memory,
          meta: %{
            node_id: node.id,
            content_preview: String.slice(node.content, 0, 100)
          }
        })

        {:ok, node}

      error ->
        error
    end
  end

  def list_nodes(opts \\ []) do
    Node
    |> order_by([n], desc: n.inserted_at)
    |> limit(^Keyword.get(opts, :limit, 100))
    |> Repo.all()
  end

  @doc """
  Get all nodes in the slipbox (unprocessed).
  """
  def get_slipbox_nodes(opts \\ []) do
    Node
    |> where([n], is_nil(n.processed_at))
    |> order_by([n], asc: n.inserted_at)
    |> limit(^Keyword.get(opts, :limit, 100))
    |> Repo.all()
  end

  @doc """
  Get a node by ID.
  """
  def get_node(id) do
    Repo.get(Node, id)
  end

  @doc """
  Mark a node as processed (integrated into the graph).
  """
  def mark_processed(node_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(n in Node, where: n.id == ^node_id)
    |> Repo.update_all(set: [processed_at: now])

    Events.broadcast(:memory_node_processed, %{
      source: :memory,
      meta: %{node_id: node_id}
    })

    :ok
  end

  # --- Links ---

  def create_link(node_a_id, node_b_id) do
    result =
      %Link{}
      |> Link.changeset(%{node_a_id: node_a_id, node_b_id: node_b_id})
      |> Repo.insert(on_conflict: :nothing)

    case result do
      {:ok, link} ->
        Events.broadcast(:memory_link_created, %{
          source: :memory,
          meta: %{node_a_id: link.node_a_id, node_b_id: link.node_b_id}
        })

        {:ok, link}

      error ->
        error
    end
  end

  # --- Hybrid Search ---

  @doc """
  Hybrid retrieval: vector + BM25 in parallel, then expand 1-hop links.
  """
  def search(query_text, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    with {:ok, embedding} <- Manfrod.Voyage.embed_query(query_text) do
      [vector_results, bm25_results] =
        Task.await_many(
          [
            Task.async(fn -> vector_search(embedding, limit) end),
            Task.async(fn -> bm25_search(query_text, limit) end)
          ],
          :infinity
        )

      merged =
        (vector_results ++ bm25_results)
        |> Enum.uniq_by(& &1.id)
        |> Enum.take(limit)

      results = expand_with_links(merged, limit * 2)

      Events.broadcast(:memory_searched, %{
        source: :memory,
        meta: %{
          query_preview: String.slice(query_text, 0, 100),
          result_count: length(results)
        }
      })

      {:ok, results}
    end
  end

  defp vector_search(embedding, limit) do
    vec = Pgvector.new(embedding)

    Node
    |> where([n], not is_nil(n.embedding))
    |> order_by([n], cosine_distance(n.embedding, ^vec))
    |> limit(^limit)
    |> Repo.all()
  end

  defp bm25_search(query_text, limit) do
    from(n in Node,
      select: {n, score(n.id)},
      where: n.id ~> match("content", ^query_text),
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
