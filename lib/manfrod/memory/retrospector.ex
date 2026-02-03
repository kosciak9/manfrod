defmodule Manfrod.Memory.Retrospector do
  @moduledoc """
  Autonomous agent that builds the zettelkasten.

  Given unprocessed nodes (the slipbox) and tools to manipulate the graph,
  the agent decides how to integrate new knowledge. Structure emerges from
  the agent's decisions, not from prescribed rules.

  ## Tools available to the agent

  - `search` - semantic + keyword search over the graph
  - `get_node` - fetch a node by ID
  - `create_node` - create a new node (returns ID)
  - `create_link` - link two nodes by ID
  - `delete_node` - delete a node and its links (for deduplication)
  - `delete_link` - delete a link between nodes
  - `list_links` - list all nodes linked to a given node (for graph exploration)
  - `mark_processed` - mark a node as integrated into the graph
  """

  require Logger

  alias Manfrod.{Events, LLM, Memory, Voyage}

  # Embed zettelkasten guide at compile time
  @external_resource Path.join(__DIR__, "zettelkasten.md")
  @zettelkasten_guide File.read!(Path.join(__DIR__, "zettelkasten.md"))

  @system_prompt """
  You are iteratively building a zettelkasten - a personal knowledge graph for
  yourself, composed of atomic notes.

  You have access to:
  - Unprocessed notes from recent conversations (the slipbox)
  - The existing knowledge graph (via search and list_links)
  - Tools to create nodes, create links, delete nodes, delete links, and mark notes as processed

  ## Deduplication

  There is a high chance you'll find duplicates in slipbox, both duplicates of
  other slipbox items and duplicates of what's already in the graph. That's
  because we extract all interesting facts from conversations without regard to
  current contents. Your job is to keep it deduplicated.

  ## Graph Gardening

  Don't just process the slipbox - tend to the garden. Each session, go deeper:
  - Follow links from nodes you touch to see what's connected
  - Look for clusters that could use structure notes
  - Find orphans that deserve connections
  - Notice patterns emerging and create new linking opportunities
  - Consolidate near-duplicates you discover while exploring
  - Let structure emerge from your observations

  The graph is alive. You're not just adding to it - you're shaping it, pruning
  it, helping it grow in interesting directions. Log what you notice. React to
  what you find. Iterate.

  When finished, say "Done."

  Here is a guide on zettelkasten best practices:

  #{@zettelkasten_guide}
  """

  # Tool definitions
  defp tools do
    [
      ReqLLM.Tool.new!(
        name: "search",
        description:
          "Search the knowledge graph for related nodes. Uses semantic similarity and keyword matching.",
        parameter_schema: [
          query: [type: :string, required: true, doc: "Search query text"],
          limit: [type: :integer, doc: "Maximum results to return (default: 5)"]
        ],
        callback: &tool_search/1
      ),
      ReqLLM.Tool.new!(
        name: "get_node",
        description: "Fetch a specific node by its ID to see its full content.",
        parameter_schema: [
          id: [type: :string, required: true, doc: "Node UUID"]
        ],
        callback: &tool_get_node/1
      ),
      ReqLLM.Tool.new!(
        name: "create_node",
        description:
          "Create a new node in the knowledge graph. Returns the new node's ID. New nodes are created as already processed (they're derived insights, not raw observations).",
        parameter_schema: [
          content: [
            type: :string,
            required: true,
            doc: "The atomic idea or fact (1-2 sentences)"
          ]
        ],
        callback: &tool_create_node/1
      ),
      ReqLLM.Tool.new!(
        name: "create_link",
        description: "Create an undirected link between two nodes.",
        parameter_schema: [
          node_a_id: [type: :string, required: true, doc: "First node UUID"],
          node_b_id: [type: :string, required: true, doc: "Second node UUID"]
        ],
        callback: &tool_create_link/1
      ),
      ReqLLM.Tool.new!(
        name: "mark_processed",
        description:
          "Mark a slipbox node as processed (integrated into the graph). Call this when you're done working with a node.",
        parameter_schema: [
          id: [type: :string, required: true, doc: "Node UUID to mark as processed"]
        ],
        callback: &tool_mark_processed/1
      ),
      ReqLLM.Tool.new!(
        name: "delete_node",
        description:
          "Delete a node from the knowledge graph. Use this to remove duplicates. All links to/from this node are automatically deleted.",
        parameter_schema: [
          id: [type: :string, required: true, doc: "Node UUID to delete"]
        ],
        callback: &tool_delete_node/1
      ),
      ReqLLM.Tool.new!(
        name: "delete_link",
        description: "Delete a link between two nodes.",
        parameter_schema: [
          node_a_id: [type: :string, required: true, doc: "First node UUID"],
          node_b_id: [type: :string, required: true, doc: "Second node UUID"]
        ],
        callback: &tool_delete_link/1
      ),
      ReqLLM.Tool.new!(
        name: "list_links",
        description:
          "List all nodes directly linked to a given node. Use this to explore the graph structure and follow connections.",
        parameter_schema: [
          id: [type: :string, required: true, doc: "Node UUID to get links for"]
        ],
        callback: &tool_list_links/1
      )
    ]
  end

  # Tool callbacks

  def tool_search(%{query: query} = args) do
    limit = Map.get(args, :limit, 5)
    {:ok, nodes} = Memory.search(query, limit: limit)

    if Enum.empty?(nodes) do
      {:ok, "No matching nodes found."}
    else
      result =
        nodes
        |> Enum.map(fn n -> "- [#{n.id}] #{n.content}" end)
        |> Enum.join("\n")

      {:ok, "Found #{length(nodes)} nodes:\n#{result}"}
    end
  end

  def tool_get_node(%{id: id}) do
    case Memory.get_node(id) do
      nil ->
        {:ok, "Node not found: #{id}"}

      node ->
        processed = if node.processed_at, do: "yes", else: "no (in slipbox)"
        {:ok, "Node #{id}:\nContent: #{node.content}\nProcessed: #{processed}"}
    end
  end

  def tool_create_node(%{content: content}) do
    case Voyage.embed_query(content) do
      {:ok, embedding} ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        case Memory.create_node(%{
               content: content,
               embedding: embedding,
               processed_at: now
             }) do
          {:ok, node} ->
            {:ok, "Created node: #{node.id}"}

          {:error, changeset} ->
            {:ok, "Failed to create node: #{inspect(changeset.errors)}"}
        end

      {:error, reason} ->
        {:ok, "Failed to generate embedding: #{inspect(reason)}"}
    end
  end

  def tool_create_link(%{node_a_id: a, node_b_id: b}) do
    case Memory.create_link(a, b) do
      {:ok, _link} ->
        {:ok, "Linked #{a} <-> #{b}"}

      {:error, changeset} ->
        {:ok, "Failed to create link: #{inspect(changeset.errors)}"}
    end
  end

  def tool_mark_processed(%{id: id}) do
    Memory.mark_processed(id)
    {:ok, "Marked #{id} as processed"}
  end

  def tool_delete_node(%{id: id}) do
    case Memory.delete_node(id) do
      {:ok, _node} ->
        {:ok, "Deleted node: #{id}"}

      {:error, :not_found} ->
        {:ok, "Node not found: #{id}"}
    end
  end

  def tool_delete_link(%{node_a_id: a, node_b_id: b}) do
    case Memory.delete_link(a, b) do
      {:ok, _link} ->
        {:ok, "Deleted link: #{a} <-> #{b}"}

      {:error, :not_found} ->
        {:ok, "Link not found: #{a} <-> #{b}"}
    end
  end

  def tool_list_links(%{id: id}) do
    linked_nodes = Memory.get_node_links(id)

    if linked_nodes == [] do
      {:ok, "Node #{id} has no links (orphan)."}
    else
      result =
        linked_nodes
        |> Enum.map(fn n -> "- [#{n.id}] #{n.content}" end)
        |> Enum.join("\n")

      {:ok, "Node #{id} is linked to #{length(linked_nodes)} nodes:\n#{result}"}
    end
  end

  # Public API

  @doc """
  Run the retrospection agent.

  Processes the slipbox (unprocessed nodes) and also reviews a random sample
  of the existing graph for maintenance and gardening.

  Returns :ok or {:error, reason}.
  """
  def process_slipbox(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 20)
    review_size = Keyword.get(opts, :review_size, 5)

    slipbox = Memory.get_slipbox_nodes(limit: batch_size)
    review_sample = Memory.get_random_nodes(review_size)

    if slipbox == [] and review_sample == [] do
      Logger.debug("Retrospector: nothing to process (empty graph)")
      :ok
    else
      Logger.info(
        "Retrospector: processing #{length(slipbox)} slipbox nodes, reviewing #{length(review_sample)} graph nodes"
      )

      run_agent(slipbox, review_sample)
    end
  end

  # Private

  defp run_agent(slipbox, review_sample) do
    slipbox_text = format_nodes(slipbox)
    review_text = format_nodes(review_sample)

    Events.broadcast(:retrospection_started, %{
      source: :retrospector,
      meta: %{slipbox_count: length(slipbox), review_count: length(review_sample)}
    })

    user_message = build_user_message(slipbox_text, review_text)

    messages = [
      ReqLLM.Context.system(@system_prompt),
      ReqLLM.Context.user(user_message)
    ]

    case call_with_tools(messages, 0, %{
           nodes_processed: 0,
           links_created: 0,
           insights_created: 0,
           nodes_deleted: 0,
           links_deleted: 0
         }) do
      {:ok, _final_text, stats} ->
        Logger.info("Retrospector: agent completed successfully")

        Events.broadcast(:retrospection_completed, %{
          source: :retrospector,
          meta: stats
        })

        :ok

      {:error, reason} = err ->
        Logger.error("Retrospector: agent failed: #{inspect(reason)}")

        Events.broadcast(:retrospection_failed, %{
          source: :retrospector,
          meta: %{reason: inspect(reason)}
        })

        err
    end
  end

  defp format_nodes(nodes) do
    nodes
    |> Enum.map(fn n -> "- [#{n.id}] #{n.content}" end)
    |> Enum.join("\n")
  end

  defp build_user_message(slipbox_text, review_text) do
    slipbox_section =
      if slipbox_text == "" do
        "Your slipbox is empty - no new notes to process."
      else
        """
        ## Slipbox (unprocessed notes)

        #{slipbox_text}

        Process these: search for connections, deduplicate, link, and mark as processed.
        """
      end

    review_section =
      if review_text == "" do
        ""
      else
        """

        ## Graph Sample (for review)

        Here are some random nodes from your existing graph. Use list_links to explore
        their connections. Look for opportunities to improve structure, find missing
        links, or consolidate related ideas:

        #{review_text}
        """
      end

    slipbox_section <> review_section
  end

  defp call_with_tools(messages, iteration, stats) do
    if iteration > 20 do
      {:error, :max_iterations}
    else
      case LLM.generate_text(messages, tools: tools(), purpose: :retrospector) do
        {:ok, response} ->
          case ReqLLM.Response.finish_reason(response) do
            :tool_calls ->
              tool_calls = ReqLLM.Response.tool_calls(response)
              narrative = ReqLLM.Response.text(response) || ""

              Logger.debug(
                "Retrospector: executing #{length(tool_calls)} tool(s), iteration #{iteration}"
              )

              # Add assistant message with tool calls
              assistant_msg = ReqLLM.Context.assistant(narrative, tool_calls: tool_calls)
              messages_with_assistant = messages ++ [assistant_msg]

              # Execute tools, add results, and update stats
              {messages_with_results, new_stats} =
                Enum.reduce(tool_calls, {messages_with_assistant, stats}, fn tool_call,
                                                                             {msgs, acc_stats} ->
                  result = execute_tool(tool_call)

                  tool_result_msg =
                    ReqLLM.Context.tool_result(tool_call.id, tool_call.function.name, result)

                  updated_stats = update_stats(acc_stats, tool_call.function.name)
                  {msgs ++ [tool_result_msg], updated_stats}
                end)

              # Continue
              call_with_tools(messages_with_results, iteration + 1, new_stats)

            _other ->
              text = ReqLLM.Response.text(response) || ""
              Logger.debug("Retrospector: agent finished with: #{String.slice(text, 0, 100)}")
              {:ok, text, stats}
          end

        {:error, _} = err ->
          err
      end
    end
  end

  defp update_stats(stats, "mark_processed"), do: Map.update!(stats, :nodes_processed, &(&1 + 1))
  defp update_stats(stats, "create_link"), do: Map.update!(stats, :links_created, &(&1 + 1))
  defp update_stats(stats, "create_node"), do: Map.update!(stats, :insights_created, &(&1 + 1))
  defp update_stats(stats, "delete_node"), do: Map.update!(stats, :nodes_deleted, &(&1 + 1))
  defp update_stats(stats, "delete_link"), do: Map.update!(stats, :links_deleted, &(&1 + 1))
  defp update_stats(stats, _tool), do: stats

  defp execute_tool(tool_call) do
    tool_name = tool_call.function.name
    args_json = tool_call.function.arguments

    case Jason.decode(args_json) do
      {:ok, args} ->
        tool = Enum.find(tools(), &(&1.name == tool_name))

        if tool do
          case ReqLLM.Tool.execute(tool, args) do
            {:ok, result} -> result
            {:error, reason} -> "Tool error: #{inspect(reason)}"
          end
        else
          "Unknown tool: #{tool_name}"
        end

      {:error, _} ->
        "Failed to parse tool arguments"
    end
  end
end
