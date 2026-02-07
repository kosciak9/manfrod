#!/bin/bash
set -euo pipefail

REPO_URL="https://github.com/${GITHUB_REPO:-kosciak9/manfrod}.git"
BRANCH="${GITHUB_BRANCH:-main}"
APP_DIR="/app"

echo "==> Manfrod Assistant starting..."
echo "    Repo: ${REPO_URL} (${BRANCH})"

# Clone fresh from GitHub (ephemeral design)
# Pre-installed deps from the image layer are in /app already,
# so we clone into a temp dir and merge.
if [ ! -d "${APP_DIR}/.git" ]; then
  echo "==> Cloning repository..."
  cd /tmp
  git clone --depth 1 --branch "${BRANCH}" "${REPO_URL}" repo
  # Move source into app dir (deps are already there from image build)
  cp -r /tmp/repo/lib "${APP_DIR}/"
  cp -r /tmp/repo/priv "${APP_DIR}/"
  cp -r /tmp/repo/assets "${APP_DIR}/" 2>/dev/null || true
  cp -r /tmp/repo/config "${APP_DIR}/"
  cp /tmp/repo/mix.exs "${APP_DIR}/"
  cp /tmp/repo/mix.lock "${APP_DIR}/"
  # Initialize git in app dir for Builder agent
  mv /tmp/repo/.git "${APP_DIR}/"
  rm -rf /tmp/repo
  cd "${APP_DIR}"
else
  echo "==> Repository already present, pulling latest..."
  cd "${APP_DIR}"
  git fetch origin "${BRANCH}"
  git reset --hard "origin/${BRANCH}"
fi

# Install/update dependencies (most are cached from image build)
echo "==> Installing dependencies..."
mix deps.get

# Compile
echo "==> Compiling..."
mix compile

# Build CSS assets
echo "==> Building assets..."
mix assets.deploy 2>/dev/null || true

# Run database migrations
echo "==> Running migrations..."
mix ecto.migrate

# Start the Phoenix server
echo "==> Starting Phoenix server on port ${PORT:-4000}..."
exec mix phx.server
