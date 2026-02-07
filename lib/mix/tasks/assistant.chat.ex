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

  defp loop(pending_choices \\ nil) do
    case IO.gets("you> ") do
      :eof ->
        IO.puts("\nGoodbye!")

      line ->
        input = String.trim(line)

        cond do
          input in ["exit", "quit"] ->
            IO.puts("Goodbye!")

          input == "" ->
            loop(pending_choices)

          true ->
            # Resolve numbered choice if pending
            content = resolve_choice(input, pending_choices)

            Assistant.send_message(%{
              content: content,
              source: :cli,
              reply_to: self()
            })

            wait_for_response()
        end
    end
  end

  defp resolve_choice(input, nil), do: input

  defp resolve_choice(input, choices) do
    case Integer.parse(input) do
      {n, ""} when n >= 1 and n <= length(choices) ->
        choice = Enum.at(choices, n - 1)
        IO.puts("  → #{choice.label}")
        choice.value

      _ ->
        # Not a number or out of range — send raw input
        input
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

      {:activity,
       %{
         type: :presenting_choices,
         source: :cli,
         meta: %{question: question, choices: choices}
       }} ->
        # Display numbered choices
        IO.puts("\nmanfrod> #{question}\n")

        choices
        |> Enum.with_index(1)
        |> Enum.each(fn {%{label: label}, i} ->
          IO.puts("  #{i}. #{label}")
        end)

        IO.puts("")

        # Continue waiting — the LLM will send a final response after presenting choices
        # Pass choices back to the loop for number resolution
        wait_for_response_with_choices(choices)

      {:activity, %{type: :responding, source: :cli, meta: %{content: content}}} ->
        IO.puts("\nmanfrod> #{content}\n")
        loop()

      {:activity, %{type: :idle}} ->
        # Conversation closing, no action needed
        loop()

      {:activity, _other} ->
        # Ignore events from other sources or types
        wait_for_response()
    after
      300_000 ->
        IO.puts("\n[timeout - no response after 5 minutes]")
        loop()
    end
  end

  # After presenting choices, continue waiting for the LLM's final response
  # then loop with the pending choices for number resolution
  defp wait_for_response_with_choices(choices) do
    receive do
      {:activity, %{type: :responding, source: :cli, meta: %{content: content}}} ->
        IO.puts("\nmanfrod> #{content}\n")
        loop(choices)

      {:activity, %{type: :idle}} ->
        loop(choices)

      {:activity, _other} ->
        wait_for_response_with_choices(choices)
    after
      300_000 ->
        IO.puts("\n[timeout - no response after 5 minutes]")
        loop(choices)
    end
  end
end
