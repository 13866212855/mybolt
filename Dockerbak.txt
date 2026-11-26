# ---- build stage ----
FROM node:22.23.5-bookworm-slim AS build
WORKDIR /app

# CI-friendly env
ENV HUSKY=0
ENV CI=true

# Route corepack (pnpm) downloads through npmmirror to survive CN network
ENV COREPACK_NPM_REGISTRY=https://registry.npmmirror.com

# Anti dead-proxy prefix for every networked RUN (Docker Desktop injects host proxy)
# Use pnpm
RUN unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy NO_PROXY no_proxy; \
    corepack enable && corepack prepare pnpm@9.15.9 --activate

# Ensure git is available for build and runtime scripts
# apt via tsinghua mirror with retries; fallback to official mirror on failure
RUN unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy NO_PROXY no_proxy; \
    sed -i 's|deb.debian.org|mirrors.tuna.tsinghua.edu.cn|g' /etc/apt/sources.list.d/debian.sources 2>/dev/null; \
    apt-get update -o Acquire::Retries=3 \
    && apt-get install -y --no-install-recommends -o Acquire::Retries=3 git \
    || { sed -i 's|mirrors.tuna.tsinghua.edu.cn|deb.debian.org|g' /etc/apt/sources.list.d/debian.sources 2>/dev/null; \
         apt-get update -o Acquire::Retries=3 && apt-get install -y --no-install-recommends -o Acquire::Retries=3 git; }; \
    rm -rf /var/lib/apt/lists/*

# Accept (optional) build-time public URL for Remix/Vite (Coolify can pass it)
ARG VITE_PUBLIC_APP_URL
ENV VITE_PUBLIC_APP_URL=${VITE_PUBLIC_APP_URL}

# Default OpenAI-like provider endpoint (apihub), baked into the client bundle.
# The API key itself is NOT baked here - inject it at runtime via docker run -e.
ARG OPENAI_LIKE_API_BASE_URL=https://apihub.agnes-ai.com/v1
ENV OPENAI_LIKE_API_BASE_URL=${OPENAI_LIKE_API_BASE_URL}

# Install deps efficiently
COPY package.json pnpm-lock.yaml* pnpm-workspace.yaml ./

# pnpm fetch via npmmirror with retry loop (anti TLS/dead-proxy); tencent fallback
# NOTE: pnpm 12 (pinned by packageManager field) removed the --network-concurrency
# CLI flag -> pass it as npm_config env var instead (ignored harmlessly if unknown)
RUN unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy NO_PROXY no_proxy; \
    ok=0; \
    for i in 1 2 3 4 5 6; do \
        if npm_config_network_concurrency=1 pnpm fetch --registry=https://registry.npmmirror.com; then ok=1; break; fi; \
        sleep 15; \
    done; \
    if [ "$ok" != "1" ]; then \
        npm_config_network_concurrency=1 pnpm fetch --registry=https://mirrors.cloud.tencent.com/npm/; \
    fi

# Copy source and build
COPY . .
# install with dev deps (needed to build)
RUN pnpm install --offline --frozen-lockfile

# Build the Remix app (SSR + client)
RUN NODE_OPTIONS=--max-old-space-size=4096 pnpm run build

# ---- production stage ----
# Vite preview loads vite.config.ts and its plugins at runtime, so it needs the
# build dependencies as well as the production dependencies.
FROM build AS bolt-ai-production
WORKDIR /app

ENV NODE_ENV=production
ENV PORT=5173
ENV HOST=0.0.0.0

# Non-sensitive build arguments
ARG VITE_LOG_LEVEL=debug
ARG DEFAULT_NUM_CTX

# Set non-sensitive environment variables
ENV WRANGLER_SEND_METRICS=false \
    VITE_LOG_LEVEL=${VITE_LOG_LEVEL} \
    DEFAULT_NUM_CTX=${DEFAULT_NUM_CTX} \
    RUNNING_IN_DOCKER=true

# Note: API keys should be provided at runtime via docker run -e or docker-compose
# Example: docker run -e OPENAI_API_KEY=your_key_here ...

# Install curl for healthchecks and verify the CA bundle for outbound HTTPS
RUN unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy NO_PROXY no_proxy; \
    sed -i 's|deb.debian.org|mirrors.tuna.tsinghua.edu.cn|g' /etc/apt/sources.list.d/debian.sources 2>/dev/null; \
    apt-get update -o Acquire::Retries=3 \
    && apt-get install -y --no-install-recommends -o Acquire::Retries=3 curl ca-certificates \
    || { sed -i 's|mirrors.tuna.tsinghua.edu.cn|deb.debian.org|g' /etc/apt/sources.list.d/debian.sources 2>/dev/null; \
         apt-get update -o Acquire::Retries=3 && apt-get install -y --no-install-recommends -o Acquire::Retries=3 curl ca-certificates; }; \
    update-ca-certificates \
    && test -s /etc/ssl/certs/ca-certificates.crt \
    && rm -rf /var/lib/apt/lists/*

# Pre-configure wrangler to disable metrics
RUN mkdir -p /root/.config/.wrangler && \
    echo '{"enabled":false}' > /root/.config/.wrangler/metrics.json

EXPOSE 5173

# Healthcheck for deployment platforms
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=5 \
  CMD curl -fsS http://localhost:5173/ || exit 1

# Start the built app with Vite's Cloudflare preview server
CMD ["pnpm", "run", "dockerstart"]


# ---- development stage ----
FROM build AS development

# Non-sensitive development arguments
ARG VITE_LOG_LEVEL=debug
ARG DEFAULT_NUM_CTX

# Set non-sensitive environment variables for development
ENV VITE_LOG_LEVEL=${VITE_LOG_LEVEL} \
    DEFAULT_NUM_CTX=${DEFAULT_NUM_CTX} \
    RUNNING_IN_DOCKER=true

# Note: API keys should be provided at runtime via docker run -e or docker-compose
# Example: docker run -e OPENAI_API_KEY=your_key_here ...

RUN mkdir -p /app/run
CMD ["pnpm", "run", "dev", "--host"]
