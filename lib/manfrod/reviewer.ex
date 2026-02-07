defmodule Manfrod.Reviewer do
  @moduledoc """
  Reviewer agent - quality gate for Builder's code changes.

  Runs after Builder (triggered by cron) and evaluates local commits
  that haven't been pushed yet. Three possible outcomes:

  - **PR submitted** (score 4-5): Pushes branch and creates a GitHub PR
  - **Changes requested** (score 2-3): Creates a task for Builder with feedback
  - **Changes rejected** (score 1): Records rejection in knowledge graph, resets to main

  The Reviewer gathers context from recent merged PRs and commits to
  calibrate its standards. Rejection notes prevent Builder from retrying
  similar approaches.
  """

  require Logger

  alias Manfrod.Events
  alias Manfrod.LLM
  alias Manfrod.Memory
  alias Manfrod.Shell
  alias Manfrod.Tasks
  alias Manfrod.Voyage

  @review_prompt """
  You are Reviewer, the quality gate agent for Manfrod.

  Your job is to evaluate code changes made by Builder and decide their fate.
  You must be fair but rigorous. Good changes that improve the system should
  be approved. Poor changes that add complexity without value should be rejected.

  ## Your evaluation criteria

  1. **Correctness**: Does the code work? Are there obvious bugs?
  2. **Value**: Does this change meaningfully improve the system?
  3. **Quality**: Is the code clean, well-structured, and following conventions?
  4. **Safety**: Are there security concerns, data loss risks, or breaking changes?
  5. **Completeness**: Is the change complete, or is it half-done?

  ## Scoring

  - **5**: Excellent change, clear improvement, well-implemented
  - **4**: Good change, minor issues that don't block merging
  - **3**: Decent idea but needs significant rework
  - **2**: Problematic - wrong approach or too many issues
  - **1**: Reject - harmful, pointless, or fundamentally broken

  ## Your response format

  You MUST respond with a JSON object (no markdown fences, just raw JSON):

  {
    "score": <1-5>,
    "title": "<short PR title if score >= 4, or description of issues>",
    "summary": "<2-3 sentence summary of the changes>",
    "assessment": "<detailed assessment explaining your score>",
    "feedback": "<specific actionable feedback for Builder if score 2-3, or rejection reason if score 1>"
  }

  Be specific and actionable in your feedback. Builder needs to understand
  exactly what to fix or why the change was rejected.
  """

  @doc """
  Run the Reviewer agent.

  Checks for local commits ahead of origin/main. If found, evaluates
  them and takes the appropriate action.

  Returns:
  - `{:ok, :no_changes}` - No local commits to review
  - `{:ok, :pr_submitted}` - PR created successfully
  - `{:ok, :changes_requested}` - Task created for Builder
  - `{:ok, :changes_rejected}` - Changes discarded, rejection recorded
  - `{:error, reason}` - Something went wrong
  """
  def run do
    Logger.info("Reviewer: starting review")

    Events.broadcast(:reviewer_started, %{
      source: :reviewer,
      meta: %{}
    })

    case get_pending_changes() do
      {:ok, :no_changes} ->
        Logger.info("Reviewer: no local changes to review")

        Events.broadcast(:reviewer_completed, %{
          source: :reviewer,
          meta: %{outcome: :no_changes}
        })

        {:ok, :no_changes}

      {:ok, %{diff: diff, commits: commits, branch: branch}} ->
        review_changes(diff, commits, branch)

      {:error, reason} = err ->
        Logger.error("Reviewer: failed to check changes: #{inspect(reason)}")

        Events.broadcast(:reviewer_failed, %{
          source: :reviewer,
          meta: %{reason: inspect(reason)}
        })

        err
    end
  end

  # Check if there are local commits ahead of origin/main
  defp get_pending_changes do
    # Fetch latest from origin
    Shell.run("git fetch origin", timeout: 30_000)

    # Get current branch
    case Shell.run("git branch --show-current") do
      {:ok, branch_raw, 0} ->
        branch = String.trim(branch_raw)

        # Check for commits ahead of origin/main
        case Shell.run("git log origin/main..HEAD --oneline") do
          {:ok, "", 0} ->
            {:ok, :no_changes}

          {:ok, commits_raw, 0} ->
            commits = String.trim(commits_raw)

            # Get the full diff
            case Shell.run("git diff origin/main..HEAD", timeout: 30_000) do
              {:ok, diff, 0} ->
                {:ok, %{diff: diff, commits: commits, branch: branch}}

              {:error, reason} ->
                {:error, {:diff_failed, reason}}
            end

          {:error, reason} ->
            {:error, {:log_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:branch_failed, reason}}
    end
  end

  # Evaluate changes using LLM and take appropriate action
  defp review_changes(diff, commits, branch) do
    Logger.info("Reviewer: evaluating changes on #{branch}")

    context = gather_context()

    # Build the review prompt with all context
    system_prompt = build_review_prompt(context)
    user_message = build_review_request(diff, commits)

    messages = [
      ReqLLM.Context.system(system_prompt),
      ReqLLM.Context.user(user_message)
    ]

    case LLM.generate_text(messages, purpose: :reviewer) do
      {:ok, response} ->
        text = ReqLLM.Response.text(response) || ""
        handle_review_response(text, diff, commits, branch)

      {:error, reason} ->
        Logger.error("Reviewer: LLM evaluation failed: #{inspect(reason)}")

        Events.broadcast(:reviewer_failed, %{
          source: :reviewer,
          meta: %{reason: inspect(reason)}
        })

        {:error, {:llm_failed, reason}}
    end
  end

  # Gather context about recent activity for calibration
  defp gather_context do
    # Recent merged PRs (for quality calibration)
    merged_prs =
      case Shell.run("gh pr list --state merged --limit 5 --json title,body,mergedAt 2>/dev/null") do
        {:ok, output, 0} -> output
        _ -> "[]"
      end

    # Recent commits on main (for context)
    recent_commits =
      case Shell.run("git log origin/main --oneline -10") do
        {:ok, output, 0} -> String.trim(output)
        _ -> "No recent commits available"
      end

    %{merged_prs: merged_prs, recent_commits: recent_commits}
  end

  defp build_review_prompt(context) do
    """
    #{@review_prompt}

    ## Context for calibration

    ### Recent merged PRs
    #{context.merged_prs}

    ### Recent commits on main
    #{context.recent_commits}
    """
  end

  defp build_review_request(diff, commits) do
    # Truncate very large diffs to avoid exceeding context limits
    truncated_diff =
      if String.length(diff) > 50_000 do
        String.slice(diff, 0, 50_000) <>
          "\n\n... [diff truncated, #{String.length(diff)} total characters]"
      else
        diff
      end

    """
    ## Commits to review

    #{commits}

    ## Full diff

    ```diff
    #{truncated_diff}
    ```

    Evaluate these changes and respond with your JSON assessment.
    """
  end

  # Parse LLM response and take appropriate action
  defp handle_review_response(text, diff, commits, branch) do
    case parse_review(text) do
      {:ok, review} ->
        Logger.info("Reviewer: scored #{review.score}/5 - #{review.title}")

        cond do
          review.score >= 4 ->
            submit_pr(review, branch)

          review.score >= 2 ->
            request_changes(review)

          true ->
            reject_changes(review, diff, commits)
        end

      {:error, reason} ->
        Logger.error("Reviewer: failed to parse review: #{inspect(reason)}")

        Events.broadcast(:reviewer_failed, %{
          source: :reviewer,
          meta: %{reason: "Failed to parse review response", raw: String.slice(text, 0, 500)}
        })

        {:error, {:parse_failed, reason}}
    end
  end

  # Parse the JSON review from LLM response
  defp parse_review(text) do
    # Try to extract JSON from the response (may have surrounding text)
    json_text =
      case Regex.run(~r/\{[\s\S]*\}/, text) do
        [json] -> json
        nil -> text
      end

    case Jason.decode(json_text) do
      {:ok, %{"score" => score, "title" => title} = data} when is_integer(score) ->
        {:ok,
         %{
           score: score,
           title: title,
           summary: Map.get(data, "summary", ""),
           assessment: Map.get(data, "assessment", ""),
           feedback: Map.get(data, "feedback", "")
         }}

      {:ok, _} ->
        {:error, :invalid_format}

      {:error, reason} ->
        {:error, {:json_decode, reason}}
    end
  end

  # Outcome 1: PR submitted (score >= 4)
  defp submit_pr(review, branch) do
    Logger.info("Reviewer: submitting PR for branch #{branch}")

    # Generate a PR branch name based on current timestamp
    pr_branch = "reviewer/#{Date.utc_today()}-#{:rand.uniform(9999)}"

    # Create and push the branch
    with {:ok, _, 0} <- Shell.run("git checkout -b #{pr_branch}"),
         {:ok, _, 0} <- Shell.run("git push -u origin #{pr_branch}", timeout: 60_000) do
      # Create the PR
      pr_body = """
      ## Summary

      #{review.summary}

      ## Assessment

      #{review.assessment}

      **Score: #{review.score}/5**

      ---
      *Reviewed automatically by Manfrod Reviewer agent*
      """

      case Shell.run(
             ~s(gh pr create --title "#{escape_shell(review.title)}" --body "#{escape_shell(pr_body)}" --base main),
             timeout: 30_000
           ) do
        {:ok, pr_url, 0} ->
          pr_url = String.trim(pr_url)
          Logger.info("Reviewer: PR created: #{pr_url}")

          # Switch back to the builder's working branch
          Shell.run("git checkout local-customisations 2>/dev/null || git checkout main")

          Events.broadcast(:reviewer_completed, %{
            source: :reviewer,
            meta: %{
              outcome: :pr_submitted,
              score: review.score,
              title: review.title,
              pr_url: pr_url,
              branch: pr_branch
            }
          })

          {:ok, :pr_submitted}

        {:ok, output, code} ->
          Logger.error("Reviewer: gh pr create failed (exit #{code}): #{output}")
          # Switch back
          Shell.run("git checkout local-customisations 2>/dev/null || git checkout main")

          Events.broadcast(:reviewer_failed, %{
            source: :reviewer,
            meta: %{reason: "PR creation failed", exit_code: code, output: output}
          })

          {:error, {:pr_create_failed, output}}

        {:error, reason} ->
          Shell.run("git checkout local-customisations 2>/dev/null || git checkout main")
          {:error, {:pr_create_failed, reason}}
      end
    else
      {:ok, output, code} ->
        Logger.error("Reviewer: branch/push failed (exit #{code}): #{output}")
        Shell.run("git checkout local-customisations 2>/dev/null || git checkout main")
        {:error, {:push_failed, output}}

      {:error, reason} ->
        Shell.run("git checkout local-customisations 2>/dev/null || git checkout main")
        {:error, {:push_failed, reason}}
    end
  end

  # Outcome 2: Changes requested (score 2-3)
  defp request_changes(review) do
    Logger.info("Reviewer: requesting changes from Builder")

    task_description = """
    Reviewer feedback (score: #{review.score}/5):

    ## Assessment
    #{review.assessment}

    ## Required changes
    #{review.feedback}

    Please address the feedback above and resubmit your changes.
    """

    case create_builder_task(task_description) do
      {:ok, task} ->
        Logger.info("Reviewer: created task #{task.id} for Builder")

        Events.broadcast(:reviewer_completed, %{
          source: :reviewer,
          meta: %{
            outcome: :changes_requested,
            score: review.score,
            title: review.title,
            task_id: task.id
          }
        })

        {:ok, :changes_requested}

      {:error, reason} ->
        Logger.error("Reviewer: failed to create task: #{inspect(reason)}")

        Events.broadcast(:reviewer_failed, %{
          source: :reviewer,
          meta: %{reason: "Failed to create feedback task"}
        })

        {:error, {:task_create_failed, reason}}
    end
  end

  # Outcome 3: Changes rejected (score 1)
  defp reject_changes(review, _diff, commits) do
    Logger.info("Reviewer: rejecting changes")

    # Create a rejection note in the knowledge graph
    rejection_content = """
    Rejected Builder changes (#{Date.utc_today()})

    ## What was attempted
    Commits: #{commits}

    ## Summary
    #{review.summary}

    ## Why rejected
    #{review.feedback}

    This rejection is recorded to prevent similar attempts.
    """

    # Create the rejection note
    case create_rejection_note(rejection_content) do
      {:ok, node_id} ->
        Logger.info("Reviewer: created rejection note #{node_id}")

      {:error, reason} ->
        Logger.warning("Reviewer: failed to create rejection note: #{inspect(reason)}")
    end

    # Reset to main (discard the rejected changes)
    case Shell.run("git reset --hard origin/main") do
      {:ok, _, 0} ->
        Logger.info("Reviewer: reset to origin/main")

      {:ok, output, code} ->
        Logger.warning("Reviewer: git reset exit #{code}: #{output}")

      {:error, reason} ->
        Logger.warning("Reviewer: git reset failed: #{inspect(reason)}")
    end

    Events.broadcast(:reviewer_completed, %{
      source: :reviewer,
      meta: %{
        outcome: :changes_rejected,
        score: review.score,
        title: review.title
      }
    })

    {:ok, :changes_rejected}
  end

  # Create a note for the rejection
  defp create_rejection_note(content) do
    embedding =
      case Voyage.embed_query(content) do
        {:ok, emb} -> emb
        {:error, _} -> nil
      end

    attrs = %{content: content}
    attrs = if embedding, do: Map.put(attrs, :embedding, embedding), else: attrs

    case Memory.create_node(attrs) do
      {:ok, node} ->
        # Link to soul for discoverability
        soul = Memory.get_soul()

        if soul do
          Memory.create_link(soul.id, node.id, context: "rejected_change")
        end

        {:ok, node.id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Create a task for Builder with feedback
  defp create_builder_task(description) do
    embedding =
      case Voyage.embed_query(description) do
        {:ok, emb} -> emb
        {:error, _} -> nil
      end

    attrs = %{content: description}
    attrs = if embedding, do: Map.put(attrs, :embedding, embedding), else: attrs

    case Memory.create_node(attrs) do
      {:ok, note} ->
        Tasks.create(%{assignee: "builder", note_id: note.id})

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Escape double quotes for shell commands
  defp escape_shell(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("`", "\\`")
    |> String.replace("$", "\\$")
  end
end
