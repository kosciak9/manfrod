defmodule Manfrod.MemoryTest do
  use Manfrod.DataCase

  alias Manfrod.Memory

  @moduletag :db

  describe "messages" do
    test "create_message/1 creates a pending message" do
      attrs = message_attrs()
      assert {:ok, msg} = Memory.create_message(attrs)
      assert msg.role == attrs.role
      assert msg.content == attrs.content
      assert is_nil(msg.conversation_id)
    end

    test "get_pending_messages/0 returns messages without conversation" do
      m1 = insert_message!(%{received_at: ~U[2024-01-01 10:00:00Z]})
      m2 = insert_message!(%{received_at: ~U[2024-01-01 10:01:00Z]})

      # Create a conversation and assign one message to it
      conv = insert_conversation!()
      Repo.update!(Ecto.Changeset.change(m2, conversation_id: conv.id))

      pending = Memory.get_pending_messages()
      assert length(pending) == 1
      assert hd(pending).id == m1.id
    end

    test "get_pending_messages/0 returns messages ordered by received_at" do
      m2 = insert_message!(%{received_at: ~U[2024-01-01 10:01:00Z]})
      m1 = insert_message!(%{received_at: ~U[2024-01-01 10:00:00Z]})
      m3 = insert_message!(%{received_at: ~U[2024-01-01 10:02:00Z]})

      pending = Memory.get_pending_messages()
      assert Enum.map(pending, & &1.id) == [m1.id, m2.id, m3.id]
    end
  end

  describe "conversations" do
    test "close_conversation/1 creates conversation and links pending messages" do
      m1 = insert_message!(%{received_at: ~U[2024-01-01 10:00:00Z]})
      m2 = insert_message!(%{received_at: ~U[2024-01-01 10:05:00Z]})

      assert {:ok, conv} = Memory.close_conversation(%{summary: "Test summary"})
      assert conv.summary == "Test summary"
      assert conv.started_at == ~U[2024-01-01 10:00:00Z]
      assert conv.ended_at == ~U[2024-01-01 10:05:00Z]

      # Messages should now be linked
      m1_reloaded = Repo.get!(Manfrod.Memory.Message, m1.id)
      m2_reloaded = Repo.get!(Manfrod.Memory.Message, m2.id)
      assert m1_reloaded.conversation_id == conv.id
      assert m2_reloaded.conversation_id == conv.id

      # No more pending messages
      assert Memory.get_pending_messages() == []
    end

    test "close_conversation/1 fails when no pending messages" do
      assert {:error, :no_pending_messages} = Memory.close_conversation(%{summary: "Test"})
    end

    test "get_conversation_with_messages/1 preloads messages" do
      m1 = insert_message!(%{received_at: ~U[2024-01-01 10:00:00Z]})
      _m2 = insert_message!(%{received_at: ~U[2024-01-01 10:05:00Z]})
      {:ok, conv} = Memory.close_conversation(%{summary: "Test"})

      loaded = Memory.get_conversation_with_messages(conv.id)
      assert length(loaded.messages) == 2
      assert m1.id in Enum.map(loaded.messages, & &1.id)
    end
  end

  describe "nodes" do
    test "create_node/1 creates a node" do
      attrs = node_attrs(%{content: "Test fact"})
      assert {:ok, node} = Memory.create_node(attrs)
      assert node.content == "Test fact"
      assert is_nil(node.processed_at)
    end

    test "list_nodes/1 returns nodes ordered by inserted_at desc" do
      # Insert directly with explicit timestamps to ensure ordering
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      earlier = NaiveDateTime.add(now, -60, :second)

      n1 =
        Repo.insert!(%Manfrod.Memory.Node{
          content: "first",
          inserted_at: earlier,
          updated_at: earlier
        })

      n2 =
        Repo.insert!(%Manfrod.Memory.Node{content: "second", inserted_at: now, updated_at: now})

      nodes = Memory.list_nodes()
      assert Enum.map(nodes, & &1.id) == [n2.id, n1.id]
    end

    test "list_nodes/1 respects limit" do
      for _ <- 1..5, do: insert_node!()
      assert length(Memory.list_nodes(limit: 3)) == 3
    end

    test "get_slipbox_nodes/1 returns unprocessed nodes" do
      n1 = insert_node!()
      n2 = insert_node!(%{processed_at: DateTime.utc_now() |> DateTime.truncate(:second)})

      slipbox = Memory.get_slipbox_nodes()
      ids = Enum.map(slipbox, & &1.id)
      assert n1.id in ids
      refute n2.id in ids
    end

    test "get_node/1 returns node by id" do
      node = insert_node!(%{content: "Find me"})
      found = Memory.get_node(node.id)
      assert found.content == "Find me"
    end

    test "mark_processed/1 sets processed_at" do
      node = insert_node!()
      assert is_nil(node.processed_at)

      :ok = Memory.mark_processed(node.id)

      reloaded = Memory.get_node(node.id)
      refute is_nil(reloaded.processed_at)
    end
  end

  describe "links" do
    test "create_link/2 creates a link between nodes" do
      n1 = insert_node!()
      n2 = insert_node!()

      assert {:ok, link} = Memory.create_link(n1.id, n2.id)
      assert link.node_a_id == min(n1.id, n2.id)
      assert link.node_b_id == max(n1.id, n2.id)
    end

    test "create_link/2 normalizes node order" do
      n1 = insert_node!()
      n2 = insert_node!()

      # Create with reversed order
      {:ok, link} = Memory.create_link(n2.id, n1.id)

      # Should still be normalized
      assert link.node_a_id == min(n1.id, n2.id)
      assert link.node_b_id == max(n1.id, n2.id)
    end

    test "create_link/2 is idempotent" do
      n1 = insert_node!()
      n2 = insert_node!()

      {:ok, _} = Memory.create_link(n1.id, n2.id)
      {:ok, _} = Memory.create_link(n1.id, n2.id)
      {:ok, _} = Memory.create_link(n2.id, n1.id)

      # Should only have one link
      count = Repo.aggregate(Manfrod.Memory.Link, :count, :id)
      assert count == 1
    end
  end

  describe "soul" do
    test "has_soul?/0 returns false when no nodes" do
      refute Memory.has_soul?()
    end

    test "has_soul?/0 returns true when nodes exist" do
      insert_node!()
      assert Memory.has_soul?()
    end

    test "get_soul/0 returns first node by insertion" do
      n1 = insert_node!(%{content: "First soul"})
      Process.sleep(10)
      _n2 = insert_node!(%{content: "Second"})

      soul = Memory.get_soul()
      assert soul.id == n1.id
      assert soul.content == "First soul"
    end
  end

  describe "build_context/1" do
    test "returns empty string for empty list" do
      assert Memory.build_context([]) == ""
    end

    test "formats nodes as bullet list" do
      n1 = insert_node!(%{content: "Fact one"})
      n2 = insert_node!(%{content: "Fact two"})

      context = Memory.build_context([n1, n2])
      assert context =~ "Relevant memories:"
      assert context =~ "Fact one"
      assert context =~ "Fact two"
    end
  end
end
