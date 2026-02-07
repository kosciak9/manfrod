defmodule Manfrod.Knowledge.Seed do
  @moduledoc """
  Deterministic soul initialization for Manfrod's knowledge graph.

  On first run (empty graph), inserts predefined nodes from markdown files
  and creates a deterministic link structure. This replaces the previous
  conversation-based soul creation approach.

  Idempotent: checks `Memory.has_soul?()` before seeding.
  The entire seed runs in a single database transaction - if any node
  creation fails, everything rolls back so the next startup can retry.
  """

  require Logger

  alias Manfrod.Memory
  alias Manfrod.Repo
  alias Manfrod.Voyage

  @soul_dir Path.join(__DIR__, "soul")

  @soul_files [
    {"manfrod", "00_manfrod.md"},
    {"container", "01_container.md"},
    {"assistant", "02_assistant.md"},
    {"builder", "03_builder.md"},
    {"reviewer", "04_reviewer.md"},
    {"workflow", "05_workflow.md"},
    {"himalaya", "06_himalaya.md"},
    {"calendula", "07_calendula.md"}
  ]

  # Register external resources for recompilation on change
  for {_key, filename} <- @soul_files do
    @external_resource Path.join(@soul_dir, filename)
  end

  # Read all files at compile time
  @soul_contents Enum.map(@soul_files, fn {key, filename} ->
                   path = Path.join(@soul_dir, filename)
                   {key, File.read!(path) |> String.trim()}
                 end)

  # Directional links: {from_key, to_key, context_label}
  @links [
    {"manfrod", "container", "runs_in"},
    {"manfrod", "assistant", "has_agent"},
    {"manfrod", "builder", "has_agent"},
    {"manfrod", "reviewer", "has_agent"},
    {"manfrod", "workflow", "orchestrated_by"},
    {"assistant", "workflow", "participates_in"},
    {"builder", "workflow", "participates_in"},
    {"reviewer", "workflow", "participates_in"},
    {"workflow", "container", "deployed_via"},
    {"himalaya", "assistant", "integration"},
    {"calendula", "assistant", "integration"}
  ]

  @doc """
  Seeds the knowledge graph if it's empty.

  Creates nodes from markdown files in lib/manfrod/knowledge/soul/,
  generates embeddings, creates links, and marks all nodes as processed.

  The entire seed runs in a single database transaction - if any step
  fails, everything rolls back and the next startup will retry.

  Returns:
  - `{:ok, :seeded}` if the graph was empty and seeding succeeded
  - `{:ok, :already_seeded}` if the graph already has nodes
  - `{:error, reason}` on failure
  """
  def seed_if_empty do
    if Memory.has_soul?() do
      Logger.info("[Seed] Knowledge graph already has nodes, skipping seed")
      {:ok, :already_seeded}
    else
      Logger.info("[Seed] Empty knowledge graph detected, seeding soul...")
      seed()
    end
  end

  defp seed do
    # Step 1: Generate embeddings outside the transaction (HTTP call)
    texts = Enum.map(@soul_contents, fn {_key, content} -> content end)

    embeddings =
      case Voyage.embed(texts) do
        {:ok, embeddings} ->
          embeddings

        {:error, reason} ->
          Logger.warning(
            "[Seed] Failed to generate embeddings: #{inspect(reason)}, seeding without embeddings"
          )

          List.duplicate(nil, length(texts))
      end

    # Step 2: Create all nodes and links in a single transaction
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Repo.transaction(fn -> seed_in_transaction(embeddings, now) end) do
      {:ok, node_count} ->
        Logger.info("[Seed] Soul seeding complete! Created #{node_count} nodes")
        {:ok, :seeded}

      {:error, reason} ->
        Logger.error("[Seed] Failed to seed knowledge graph: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp seed_in_transaction(embeddings, now) do
    # Use a single base timestamp for all nodes, with the soul node
    # set 60 seconds earlier so get_soul/0 always identifies it first.
    # A 60-second gap is large enough to survive truncation to seconds.
    base_timestamp = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    soul_timestamp = NaiveDateTime.add(base_timestamp, -60, :second)

    node_map =
      @soul_contents
      |> Enum.zip(embeddings)
      |> Enum.reduce(%{}, fn {{key, content}, embedding}, acc ->
        node = build_node(key, content, embedding, now, soul_timestamp, base_timestamp)

        case Repo.insert(node) do
          {:ok, node} ->
            Memory.mark_processed(node.id)
            Logger.info("[Seed] Created node: #{key} (#{node.id})")
            Map.put(acc, key, node.id)

          {:error, reason} ->
            Repo.rollback("Failed to create node #{key}: #{inspect(reason)}")
        end
      end)

    # Create links
    Enum.each(@links, fn {from_key, to_key, context} ->
      from_id = Map.fetch!(node_map, from_key)
      to_id = Map.fetch!(node_map, to_key)

      case Memory.create_link(from_id, to_id, context: context) do
        {:ok, _link} ->
          Logger.info("[Seed] Linked: #{from_key} --[#{context}]--> #{to_key}")

        {:error, reason} ->
          Logger.warning("[Seed] Failed to link #{from_key} -> #{to_key}: #{inspect(reason)}")
      end
    end)

    # Create workspace anchor notes linked to soul
    soul_id = Map.fetch!(node_map, "manfrod")
    create_workspace_notes(soul_id, now)

    # Return count for logging
    map_size(node_map) + 2
  end

  # Build a Node struct with appropriate timestamps.
  # The "manfrod" node gets an earlier timestamp so get_soul/0 always finds it first.
  defp build_node("manfrod", content, embedding, now, soul_timestamp, _base_timestamp) do
    %Memory.Node{
      content: content,
      embedding: embedding,
      processed_at: now,
      inserted_at: soul_timestamp,
      updated_at: soul_timestamp
    }
  end

  defp build_node(_key, content, embedding, now, _soul_timestamp, base_timestamp) do
    %Memory.Node{
      content: content,
      embedding: embedding,
      processed_at: now,
      inserted_at: base_timestamp,
      updated_at: base_timestamp
    }
  end

  defp create_workspace_notes(soul_id, now) do
    workspace_notes = [
      {"Builder Log - Index of Builder agent session logs. Builder links timestamped session notes here after each run.",
       "workspace_log"},
      {"Retrospector Log - Index of Retrospector agent session logs. Retrospector links timestamped session notes here after each run.",
       "workspace_log"}
    ]

    Enum.each(workspace_notes, fn {content, context} ->
      embedding =
        case Voyage.embed([content]) do
          {:ok, [emb]} -> emb
          _ -> nil
        end

      attrs = %{content: content, processed_at: now}
      attrs = if embedding, do: Map.put(attrs, :embedding, embedding), else: attrs

      case Memory.create_node(attrs) do
        {:ok, node} ->
          Memory.mark_processed(node.id)
          Memory.create_link(soul_id, node.id, context: context)
          Logger.info("[Seed] Created workspace note: #{String.slice(content, 0, 40)}...")

        {:error, reason} ->
          Logger.warning("[Seed] Failed to create workspace note: #{inspect(reason)}")
      end
    end)
  end
end
