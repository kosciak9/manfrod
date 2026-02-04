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
  alias Manfrod.Voyage
  alias Manfrod.Memory.{Conversation, Message, Node, Link, QueryExpander, RecurringReminder}

  # Relevance threshold for filtering search results (cosine distance)
  # Lower = more strict, higher = more permissive
  # Cosine distance ranges from 0 (identical) to 2 (opposite)
  @relevance_threshold 0.4

  # RRF constant (k) - higher values give more weight to lower-ranked results
  @rrf_k 60

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

  @doc """
  Get conversations from the last N hours with their messages preloaded.
  Useful for self-improvement retrospectives.
  """
  def get_recent_conversations(hours \\ 24) do
    cutoff = DateTime.utc_now() |> DateTime.add(-hours, :hour)

    Conversation
    |> where([c], c.ended_at >= ^cutoff)
    |> order_by([c], desc: c.ended_at)
    |> preload(:messages)
    |> Repo.all()
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

  @doc """
  Delete a node and all its links (cascade).
  Returns {:ok, node} or {:error, :not_found}.
  """
  def delete_node(node_id) do
    case get_node(node_id) do
      nil ->
        {:error, :not_found}

      node ->
        # Delete all links involving this node
        from(l in Link,
          where: l.node_a_id == ^node_id or l.node_b_id == ^node_id
        )
        |> Repo.delete_all()

        # Delete the node
        Repo.delete(node)

        Events.broadcast(:memory_node_deleted, %{
          source: :memory,
          meta: %{node_id: node_id}
        })

        {:ok, node}
    end
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

  @doc """
  Delete a link between two nodes.
  Returns {:ok, link} or {:error, :not_found}.
  """
  def delete_link(node_a_id, node_b_id) do
    # Normalize order (same logic as Link changeset)
    {a, b} = if node_a_id < node_b_id, do: {node_a_id, node_b_id}, else: {node_b_id, node_a_id}

    case Repo.get_by(Link, node_a_id: a, node_b_id: b) do
      nil ->
        {:error, :not_found}

      link ->
        Repo.delete(link)

        Events.broadcast(:memory_link_deleted, %{
          source: :memory,
          meta: %{node_a_id: a, node_b_id: b}
        })

        {:ok, link}
    end
  end

  @doc """
  Get all linked nodes for a given node.
  Returns a list of nodes that are directly connected.
  """
  def get_node_links(node_id) do
    from(n in Node,
      join: l in Link,
      on:
        (l.node_a_id == ^node_id and l.node_b_id == n.id) or
          (l.node_b_id == ^node_id and l.node_a_id == n.id),
      distinct: n.id
    )
    |> Repo.all()
  end

  @doc """
  Get a random sample of processed nodes from the graph.
  Useful for graph review and maintenance.
  """
  def get_random_nodes(limit \\ 10) do
    Node
    |> where([n], not is_nil(n.processed_at))
    |> order_by(fragment("RANDOM()"))
    |> limit(^limit)
    |> Repo.all()
  end

  # --- Graph Visualization ---

  @doc """
  Get all graph data for visualization.

  Returns a map with nodes and edges suitable for graph rendering.

  ## Options

    * `:filter` - Filter nodes: `:all` (default), `:processed`, or `:slipbox`

  ## Example

      %{
        nodes: [
          %{
            id: "uuid",
            content: "full content",
            content_preview: "first 100 chars...",
            processed: true,
            link_count: 5,
            inserted_at: ~U[2024-01-01 00:00:00Z]
          }
        ],
        edges: [
          %{source: "uuid-a", target: "uuid-b"}
        ]
      }
  """
  def get_graph_data(opts \\ []) do
    filter = Keyword.get(opts, :filter, :all)

    # Fetch nodes based on filter
    nodes_query =
      case filter do
        :processed ->
          from(n in Node, where: not is_nil(n.processed_at))

        :slipbox ->
          from(n in Node, where: is_nil(n.processed_at))

        :all ->
          from(n in Node)
      end

    nodes = Repo.all(nodes_query)
    node_ids = Enum.map(nodes, & &1.id) |> MapSet.new()

    # Count links per node
    link_counts =
      from(l in Link,
        select: {l.node_a_id, l.node_b_id}
      )
      |> Repo.all()
      |> Enum.flat_map(fn {a, b} -> [{a, 1}, {b, 1}] end)
      |> Enum.reduce(%{}, fn {id, count}, acc ->
        Map.update(acc, id, count, &(&1 + count))
      end)

    # Fetch edges (only between visible nodes)
    edges =
      from(l in Link,
        where:
          l.node_a_id in ^MapSet.to_list(node_ids) and l.node_b_id in ^MapSet.to_list(node_ids),
        select: %{source: l.node_a_id, target: l.node_b_id}
      )
      |> Repo.all()

    # Transform nodes for visualization
    nodes_data =
      Enum.map(nodes, fn node ->
        %{
          id: node.id,
          content: node.content,
          content_preview: String.slice(node.content || "", 0, 100),
          processed: not is_nil(node.processed_at),
          link_count: Map.get(link_counts, node.id, 0),
          inserted_at: node.inserted_at
        }
      end)

    %{nodes: nodes_data, edges: edges}
  end

  # --- Hybrid Search with Query Expansion ---

  @doc """
  Hybrid retrieval with query expansion and reranking.

  1. Expands the query into multiple search queries using LLM
  2. Runs vector + BM25 search for each expanded query in parallel
  3. Merges results using Reciprocal Rank Fusion (RRF)
  4. Reranks top candidates using Voyage reranker
  5. Filters by relevance threshold
  6. Expands with 1-hop links

  Returns `{:ok, nodes}` where nodes is a list of Node structs.

  ## Options

    * `:limit` - Maximum number of results (default: 10)
    * `:expand_query` - Whether to use query expansion (default: true)
    * `:rerank` - Whether to use Voyage reranker (default: true)
  """
  def search(query_text, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    expand_query? = Keyword.get(opts, :expand_query, true)
    rerank? = Keyword.get(opts, :rerank, true)

    # Step 1: Query expansion (always succeeds with fallback to original)
    {:ok, queries} =
      if expand_query? do
        QueryExpander.expand(query_text)
      else
        {:ok, [query_text]}
      end

    # Step 2: Parallel search for each query
    search_tasks =
      Enum.flat_map(queries, fn query ->
        [
          Task.async(fn -> {:vector, query, search_vector(query, limit)} end),
          Task.async(fn -> {:bm25, query, search_bm25(query, limit)} end)
        ]
      end)

    search_results = Task.await_many(search_tasks, :infinity)

    # Step 3: Collect results by type and merge with RRF
    vector_results =
      search_results
      |> Enum.filter(fn {type, _, _} -> type == :vector end)
      |> Enum.flat_map(fn {_, _, results} -> results end)

    bm25_results =
      search_results
      |> Enum.filter(fn {type, _, _} -> type == :bm25 end)
      |> Enum.flat_map(fn {_, _, results} -> results end)

    # RRF merge - combine vector and BM25 results
    merged = rrf_merge([vector_results, bm25_results])

    # Step 4: Rerank top candidates using Voyage (if enabled and we have results)
    reranked =
      if rerank? and length(merged) > 1 do
        rerank_nodes(query_text, merged, limit * 2)
      else
        merged
      end

    # Step 5: Filter by relevance threshold
    # Only keep nodes where at least one search returned them with good distance
    min_distances = compute_min_distances(vector_results)

    filtered =
      reranked
      |> Enum.filter(fn node ->
        case Map.get(min_distances, node.id) do
          # BM25-only results pass through
          nil -> true
          distance -> distance <= @relevance_threshold
        end
      end)
      |> Enum.take(limit)

    # Step 6: Expand with 1-hop links
    results = expand_with_links(filtered, limit * 2)

    Events.broadcast(:memory_searched, %{
      source: :memory,
      meta: %{
        query_preview: String.slice(query_text, 0, 100),
        expanded_queries: length(queries),
        reranked: rerank? and length(merged) > 1,
        result_count: length(results)
      }
    })

    {:ok, results}
  end

  @doc """
  Search using only vector similarity (no query expansion).
  Returns `[{node, distance}]` tuples sorted by distance ascending.
  """
  def search_vector(query_text, limit \\ 10) do
    case Manfrod.Voyage.embed_query(query_text) do
      {:ok, embedding} ->
        vector_search_with_distance(embedding, limit)

      {:error, _} ->
        []
    end
  end

  @doc """
  Search using only BM25 keyword matching.
  Returns list of nodes sorted by BM25 score descending.
  """
  def search_bm25(query_text, limit \\ 10) do
    bm25_search(query_text, limit)
  end

  # Vector search returning {node, distance} tuples
  defp vector_search_with_distance(embedding, limit) do
    vec = Pgvector.new(embedding)

    from(n in Node,
      where: not is_nil(n.embedding),
      select: {n, cosine_distance(n.embedding, ^vec)},
      order_by: cosine_distance(n.embedding, ^vec),
      limit: ^limit
    )
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

  # Compute minimum distance per node from vector results
  defp compute_min_distances(vector_results) do
    vector_results
    |> Enum.reduce(%{}, fn {node, distance}, acc ->
      Map.update(acc, node.id, distance, &min(&1, distance))
    end)
  end

  # Rerank nodes using Voyage reranker
  # Returns nodes reordered by relevance score
  defp rerank_nodes(query, nodes, top_k) do
    # Take top candidates for reranking (limit API call size)
    candidates = Enum.take(nodes, top_k)

    # Extract content for reranking
    documents = Enum.map(candidates, & &1.content)

    case Voyage.rerank(query, documents, top_k: top_k) do
      {:ok, rankings} ->
        # Rankings come as [%{index: i, relevance_score: score}, ...] sorted by score
        # Map back to nodes in new order
        Enum.map(rankings, fn %{index: idx} ->
          Enum.at(candidates, idx)
        end)

      {:error, _reason} ->
        # On reranker failure, fall back to original order
        candidates
    end
  end

  @doc """
  Reciprocal Rank Fusion - merges multiple ranked lists into one.

  Each input list can be either:
  - List of nodes (from BM25)
  - List of {node, score} tuples (from vector search)

  Returns a list of nodes sorted by combined RRF score.
  """
  def rrf_merge(ranked_lists) do
    # Normalize all lists to just nodes while tracking ranks
    ranked_lists
    |> Enum.with_index()
    |> Enum.flat_map(fn {list, _list_idx} ->
      list
      # Ranks start at 1
      |> Enum.with_index(1)
      |> Enum.map(fn {item, rank} ->
        node = normalize_to_node(item)
        {node.id, node, rank}
      end)
    end)
    |> Enum.group_by(fn {id, _node, _rank} -> id end)
    |> Enum.map(fn {_id, entries} ->
      # Get the node from first entry
      {_, node, _} = hd(entries)

      # Sum RRF scores across all lists
      rrf_score =
        entries
        |> Enum.map(fn {_, _, rank} -> 1.0 / (@rrf_k + rank) end)
        |> Enum.sum()

      {node, rrf_score}
    end)
    |> Enum.sort_by(fn {_node, score} -> score end, :desc)
    |> Enum.map(fn {node, _score} -> node end)
  end

  defp normalize_to_node({node, _score}), do: node
  defp normalize_to_node(node), do: node

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

  # --- Recurring Reminders ---

  @doc """
  List recurring reminders.

  ## Options

    * `:enabled` - Filter by enabled status (true/false). Default: all.
    * `:preload` - Preload associations. Default: [:node].
  """
  def list_recurring_reminders(opts \\ []) do
    query =
      case Keyword.get(opts, :enabled) do
        nil -> from(r in RecurringReminder)
        enabled -> from(r in RecurringReminder, where: r.enabled == ^enabled)
      end

    preload = Keyword.get(opts, :preload, [:node])

    query
    |> order_by([r], asc: r.name)
    |> preload(^preload)
    |> Repo.all()
  end

  @doc """
  Get a recurring reminder by ID with node preloaded.
  """
  def get_recurring_reminder(id) do
    RecurringReminder
    |> where([r], r.id == ^id)
    |> preload(:node)
    |> Repo.one()
  end

  @doc """
  Get a recurring reminder by name with node preloaded.
  """
  def get_recurring_reminder_by_name(name) do
    RecurringReminder
    |> where([r], r.name == ^name)
    |> preload(:node)
    |> Repo.one()
  end

  @doc """
  Create a recurring reminder.

  Expects attrs with :name, :cron, and :node_id.
  Optional: :timezone (default "Europe/Warsaw"), :enabled (default true).
  """
  def create_recurring_reminder(attrs) do
    result =
      %RecurringReminder{}
      |> RecurringReminder.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, reminder} ->
        Events.broadcast(:recurring_reminder_created, %{
          source: :memory,
          meta: %{reminder_id: reminder.id, name: reminder.name}
        })

        {:ok, Repo.preload(reminder, :node)}

      error ->
        error
    end
  end

  @doc """
  Update a recurring reminder.

  If the cron expression changes, all pending Oban jobs for this reminder
  are cancelled so the SchedulerWorker can reschedule with the new pattern.
  """
  def update_recurring_reminder(%RecurringReminder{} = reminder, attrs) do
    changeset = RecurringReminder.changeset(reminder, attrs)
    cron_changed? = Ecto.Changeset.get_change(changeset, :cron) != nil

    result = Repo.update(changeset)

    case result do
      {:ok, updated} ->
        if cron_changed? do
          cancel_pending_trigger_jobs(updated.id)
        end

        Events.broadcast(:recurring_reminder_updated, %{
          source: :memory,
          meta: %{reminder_id: updated.id, name: updated.name, cron_changed: cron_changed?}
        })

        {:ok, Repo.preload(updated, :node, force: true)}

      error ->
        error
    end
  end

  @doc """
  Delete a recurring reminder.

  Accepts either a RecurringReminder struct or an ID string.
  Cancels all pending Oban jobs for this reminder before deletion.
  """
  def delete_recurring_reminder(%RecurringReminder{} = reminder) do
    cancel_pending_trigger_jobs(reminder.id)

    case Repo.delete(reminder) do
      {:ok, deleted} ->
        Events.broadcast(:recurring_reminder_deleted, %{
          source: :memory,
          meta: %{reminder_id: deleted.id, name: deleted.name}
        })

        {:ok, deleted}

      error ->
        error
    end
  end

  def delete_recurring_reminder(id) when is_binary(id) do
    case get_recurring_reminder(id) do
      nil -> {:error, :not_found}
      reminder -> delete_recurring_reminder(reminder)
    end
  end

  # Cancels all pending TriggerWorker jobs for a specific recurring reminder.
  defp cancel_pending_trigger_jobs(reminder_id) do
    import Ecto.Query

    # Find all scheduled/available TriggerWorker jobs for this reminder
    job_ids =
      from(j in Oban.Job,
        where: j.worker == "Manfrod.Workers.TriggerWorker",
        where: j.state in ["scheduled", "available"],
        where: fragment("?->>'recurring_reminder_id' = ?", j.args, ^reminder_id),
        select: j.id
      )
      |> Repo.all()

    # Cancel each job
    Enum.each(job_ids, &Oban.cancel_job/1)

    length(job_ids)
  end

  # --- Context Building ---

  @doc """
  Build memory context string for injection into prompts.

  Formats nodes with their UUIDs for reference. The LLM can use
  `recall_memory` to search for more memories or `get_memory` to
  fetch a specific node by ID.
  """
  def build_context([]), do: ""

  def build_context(nodes) do
    items =
      nodes
      |> Enum.map(fn node -> "- [#{node.id}] #{node.content}" end)
      |> Enum.join("\n")

    """
    Relevant memories (use recall_memory to search for more, get_memory to fetch by ID):
    #{items}
    """
    |> String.trim()
  end
end
