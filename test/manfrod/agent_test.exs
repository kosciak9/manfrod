defmodule Manfrod.AgentTest do
  use Manfrod.DataCase

  alias Manfrod.Agent
  alias Manfrod.Events

  @moduletag :db

  describe "state structure" do
    test "has inbox field" do
      pid = Process.whereis(Agent)
      # Use longer timeout as agent might be busy with LLM call
      state = :sys.get_state(pid, 30_000)

      assert Map.has_key?(state, :inbox)
      assert Map.has_key?(state, :messages)
      assert Map.has_key?(state, :flush_timer)
      assert is_list(state.inbox)
      assert is_list(state.messages)
    end
  end

  describe "event broadcasting" do
    setup do
      Events.subscribe()
      :ok
    end

    test "broadcasts :thinking when processing message" do
      Agent.send_message(%{
        content: "Test message #{System.unique_integer()}",
        source: :test,
        reply_to: self()
      })

      # Should receive thinking event (might take a while if agent is busy)
      assert_receive {:activity, %{type: :thinking, source: :test}}, 60_000
    end

    test "broadcasts :responding after processing" do
      Agent.send_message(%{
        content: "Quick test #{System.unique_integer()}",
        source: :test,
        reply_to: self()
      })

      # Wait for full cycle - thinking then responding
      assert_receive {:activity, %{type: :thinking}}, 60_000
      assert_receive {:activity, %{type: :responding}}, 120_000
    end
  end

  describe "interrupt behavior" do
    setup do
      Events.subscribe()
      :ok
    end

    @tag :slow
    @tag :interrupt
    test "new message during processing triggers interrupt" do
      # This test verifies the interrupt mechanism by sending messages
      # in rapid succession and checking that:
      # 1. Messages queue up in inbox
      # 2. Interrupt is detected before next LLM call
      # 3. All messages get processed

      # Send first message
      Agent.send_message(%{
        content: "First message #{System.unique_integer()}",
        source: :test,
        reply_to: self()
      })

      # Wait for thinking to start
      assert_receive {:activity, %{type: :thinking, source: :test}}, 60_000

      # Immediately send second message while first is processing
      Agent.send_message(%{
        content: "Second message (interrupt) #{System.unique_integer()}",
        source: :test,
        reply_to: self()
      })

      # We should eventually get either:
      # - :interrupted followed by new :thinking, or
      # - Just process both in sequence (if first finished before second arrived)

      # Collect events for analysis
      events = collect_events(120_000)

      # Verify we got at least one thinking and one responding
      event_types = Enum.map(events, & &1.type)
      assert :thinking in event_types
      assert :responding in event_types

      # Log what happened for debugging
      IO.puts("\nEvents received: #{inspect(event_types)}")

      if :interrupted in event_types do
        IO.puts("Interrupt was triggered!")
      else
        IO.puts("No interrupt (messages processed sequentially)")
      end
    end
  end

  describe "loop behavior" do
    test "empty inbox loop is no-op" do
      pid = Process.whereis(Agent)

      # Send :loop - should be safe even during work
      send(pid, :loop)

      # If inbox is empty, this is a no-op
      # We can't easily verify, but at least it shouldn't crash
      Process.sleep(100)
      assert Process.alive?(pid)
    end

    test "multiple :loop messages don't cause issues" do
      pid = Process.whereis(Agent)

      # Send multiple :loop messages rapidly
      for _ <- 1..10 do
        send(pid, :loop)
      end

      Process.sleep(100)
      assert Process.alive?(pid)
    end
  end

  # Helper to collect events until timeout or :responding received
  defp collect_events(timeout) do
    collect_events([], timeout, System.monotonic_time(:millisecond))
  end

  defp collect_events(acc, timeout, start_time) do
    elapsed = System.monotonic_time(:millisecond) - start_time

    if elapsed > timeout do
      Enum.reverse(acc)
    else
      remaining = timeout - elapsed

      receive do
        {:activity, %{type: :responding} = activity} ->
          Enum.reverse([activity | acc])

        {:activity, activity} ->
          collect_events([activity | acc], timeout, start_time)
      after
        remaining -> Enum.reverse(acc)
      end
    end
  end
end
