# Manfrod Assistant - Containerfile
#
# Ephemeral by design: code modifications are lost on restart.
# Only changes that pass through Reviewer (PR -> merge) persist.
# The entrypoint clones from GitHub on every start, so local
# commits (e.g. from Builder) are discarded on restart.
#
# Build:
#   podman build -t manfrod -f Containerfile .
#
# Run:
#   podman run -d --name manfrod \
#     -e DATABASE_URL=ecto://manfrod:pass@host:5432/manfrod \
#     -e SECRET_KEY_BASE=$(mix phx.gen.secret) \
#     -e CLOAK_KEY=$(elixir -e ':crypto.strong_rand_bytes(32) |> Base.encode64() |> IO.puts()') \
#     -e GITHUB_REPO=kosciak9/manfrod \
#     -p 4000:4000 \
#     manfrod

FROM docker.io/hexpm/elixir:1.18.2-erlang-27.3.4.7-alpine-3.21.6@sha256:54cf07f496c28c6aca13e23b79b2892b788f7e3a3fc78ea7740fe3f2ca51b64e

# Install runtime and build dependencies
RUN apk add --no-cache \
    git \
    github-cli \
    postgresql-client \
    curl \
    bash \
    build-base

# Install hex and rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Create non-root user with home directory
RUN adduser -D -s /bin/bash manfrod

# Pre-install dependencies into a cached layer for faster startup.
# The entrypoint will run `mix deps.get` again, but this layer means
# most deps are already present and only diffs need fetching.
WORKDIR /app
COPY mix.exs mix.lock ./
RUN mix deps.get && \
    mix deps.compile
COPY config config

# Transfer ownership to manfrod user
RUN chown -R manfrod:manfrod /app

# Copy entrypoint
COPY --chown=manfrod:manfrod entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Switch to non-root user
USER manfrod

# Configure git for Builder agent commits
RUN git config --global user.name "Manfrod Assistant" && \
    git config --global user.email "assistant@manfrod.local"

# Default port
ENV PORT=4000
EXPOSE 4000

# Health check - /health is accessible even during setup mode
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
  CMD curl -sf http://localhost:${PORT}/health || exit 1

ENTRYPOINT ["/entrypoint.sh"]
