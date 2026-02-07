defmodule Mix.Tasks.Assistant.Chat do
  @moduledoc """
  Interactive CLI chat with the Assistant.

  A thin adapter that reads lines from stdin, sends them to the
  shared Assistant core, and prints responses to stdout.

      mix assistant.chat

  Type `exit` or `quit` to end the session, or press Ctrl+C.
  """
  use Mix.Task

  alias Manfrod.Assistant
  alias Manfrod.Events

  @shortdoc "Chat with the Assistant via CLI"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    # Subscribe to activity events
    Events.subscribe()

    IO.puts("Manfrod CLI Chat")
    IO.puts("Type 'exit' or 'quit' to end the session.\n")

    loop()
  end

  defp loop do
    case IO.gets("you> ") do
      :eof ->
        IO.puts("\nGoodbye!")

      line ->
        input = String.trim(line)

        cond do
          input in ["exit", "quit"] ->
            IO.puts("Goodbye!")

          input == "" ->
            loop()

          true ->
            Assistant.send_message(%{
              content: input,
              source: :cli,
              reply_to: self()
            })

            wait_for_response()
            loop()
        end
    end
  end

  defp wait_for_response do
    receive do
      {:activity, %{type: :thinking, source: :cli}} ->
        IO.write("thinking...")
        wait_for_response()

      {:activity, %{type: :narrating, source: :cli, meta: %{text: text}}} ->
        IO.puts("\n  #{text}")
        wait_for_response()

      {:activity, %{type: :action_started, source: :cli, meta: %{action: action}}} ->
        IO.write(" [#{action}]")
        wait_for_response()

      {:activity, %{type: :action_completed, source: :cli}} ->
        wait_for_response()

      {:activity, %{type: :responding, source: :cli, meta: %{content: content}}} ->
        IO.puts("\nmanfrod> #{content}\n")

      {:activity, %{type: :idle}} ->
        # Conversation closing, no action needed
        :ok

      {:activity, _other} ->
        # Ignore events from other sources or types
        wait_for_response()
    after
      300_000 ->
        IO.puts("\n[timeout - no response after 5 minutes]")
    end
  end
end
