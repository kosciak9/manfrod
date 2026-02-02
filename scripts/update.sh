#!/bin/bash
#
# Self-update script for Manfrod.
#
# Flow:
#   1. Save current commit SHA for rollback
#   2. git fetch + rebase onto origin/main
#   3. mix deps.get (if mix.lock changed)
#   4. mix compile (rollback git on failure)
#   5. mix ecto.migrate
#   6. sudo systemctl restart manfrod
#
# Usage:
#   ./scripts/update.sh
#
# The agent can call this via run_shell tool.

set -e

# Change to repo root (script is in scripts/)
cd "$(dirname "$0")/.."

echo "=== Manfrod Self-Update ==="
echo "Started at: $(date)"
echo ""

# 1. Save current state for rollback
CURRENT_SHA=$(git rev-parse HEAD)
LOCK_HASH=$(md5sum mix.lock 2>/dev/null | cut -d' ' -f1 || echo "none")

echo "Current commit: $CURRENT_SHA"
echo "Current lock hash: $LOCK_HASH"
echo ""

# 2. Fetch and rebase
echo ">>> Fetching origin..."
git fetch origin

echo ">>> Rebasing onto origin/main..."
if ! git rebase origin/main; then
    echo ""
    echo "ERROR: Rebase conflict detected!"
    echo "Aborting rebase and staying on current commit."
    git rebase --abort
    exit 1
fi

NEW_SHA=$(git rev-parse HEAD)

if [ "$CURRENT_SHA" = "$NEW_SHA" ]; then
    echo ""
    echo "Already up to date. Nothing to do."
    exit 0
fi

echo ""
echo "Updated: $CURRENT_SHA -> $NEW_SHA"
echo ""

# 3. Check if deps changed
NEW_LOCK_HASH=$(md5sum mix.lock | cut -d' ' -f1)

if [ "$LOCK_HASH" != "$NEW_LOCK_HASH" ]; then
    echo ">>> Dependencies changed, fetching..."
    mix deps.get
    echo ""
fi

# 4. Compile (rollback on failure)
echo ">>> Compiling..."
if ! mix compile; then
    echo ""
    echo "ERROR: Compilation failed!"
    echo "Rolling back to $CURRENT_SHA..."
    git reset --hard "$CURRENT_SHA"
    echo "Rollback complete. Please fix the code and try again."
    exit 1
fi
echo ""

# 5. Run migrations
echo ">>> Running migrations..."
mix ecto.migrate
echo ""

# 6. Mark update in DB so agent knows to restore context
echo ">>> Marking update in database..."
mix run -e "Manfrod.Deployment.mark_updating(\"$NEW_SHA\")"
echo ""

# 7. Restart service
# Use a background script that:
#   1. Waits a moment for this script to return output to the agent
#   2. Stops the service and waits for port to be free
#   3. Starts the service
echo ">>> Scheduling service restart..."
echo "The agent will die and come back with restored context."

# Get the port from environment or use default
PORT="${PORT:-4000}"

# Create and run a detached restart script
sudo bash -c "
  # Wait a moment for the update script to finish and return
  sleep 1
  
  # Stop the service
  systemctl stop manfrod
  
  # Wait for port to be released (max 30 seconds)
  for i in {1..30}; do
    if ! ss -tlnp | grep -q ':$PORT '; then
      break
    fi
    sleep 1
  done
  
  # Start the service
  systemctl start manfrod
" &>/dev/null &

echo ""
echo "=== Update complete ==="
echo "Finished at: $(date)"
echo ""
echo "New commit: $NEW_SHA"
echo "Restart initiated - agent will reconnect shortly."
