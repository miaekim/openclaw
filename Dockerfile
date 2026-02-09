FROM node:22-bookworm

# Install Bun (required for build scripts)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable

WORKDIR /app

ARG OPENCLAW_DOCKER_APT_PACKAGES=""
RUN if [ -n "$OPENCLAW_DOCKER_APT_PACKAGES" ]; then \
      apt-get update && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $OPENCLAW_DOCKER_APT_PACKAGES && \
      apt-get clean && \
      rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    fi

# Install git (needed to clone vox) and socat
RUN apt-get update && \
    apt-get install -y --no-install-recommends git socat && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# --- Go binaries (multi-arch via TARGETARCH) ---
ARG TARGETARCH

# gogcli: Google Suite CLI (Gmail, GCal, GDrive, GContacts) — binary is named "gog"
RUN curl -fsSL "https://github.com/steipete/gogcli/releases/download/v0.9.0/gogcli_0.9.0_linux_${TARGETARCH}.tar.gz" \
  | tar -xz -C /usr/local/bin gog && chmod +x /usr/local/bin/gog

# goplaces: Google Places CLI
RUN curl -fsSL "https://github.com/steipete/goplaces/releases/download/v0.2.1/goplaces_0.2.1_linux_${TARGETARCH}.tar.gz" \
  | tar -xz -C /usr/local/bin goplaces && chmod +x /usr/local/bin/goplaces

# --- Node-based CLIs (installed globally) ---

# summarize: Summarize URLs, YouTube, podcasts, files
RUN npm install -g @steipete/summarize

# oracle: Query GPT-5 Pro with custom context and files
RUN npm install -g @steipete/oracle

# mcporter: MCP server runtime and CLI
RUN npm install -g mcporter

# vox: Agent phone call tool (not published on npm; clone + build)
RUN git clone --depth 1 https://github.com/steipete/vox.git /tmp/vox && \
    cd /tmp/vox && npm install && npm run build && npm install -g . && \
    rm -rf /tmp/vox

COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY ui/package.json ./ui/package.json
COPY patches ./patches
COPY scripts ./scripts

RUN pnpm install --frozen-lockfile

COPY . .
RUN OPENCLAW_A2UI_SKIP_MISSING=1 pnpm build
# Force pnpm for UI build (Bun may fail on ARM/Synology architectures)
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:build

ENV NODE_ENV=production

# Allow non-root user to write temp files during runtime/tests.
RUN chown -R node:node /app

# Security hardening: Run as non-root user
# The node:22-bookworm image includes a 'node' user (uid 1000)
# This reduces the attack surface by preventing container escape via root privileges
USER node

# Start gateway server with default config.
# Binds to loopback (127.0.0.1) by default for security.
#
# For container platforms requiring external health checks:
#   1. Set OPENCLAW_GATEWAY_TOKEN or OPENCLAW_GATEWAY_PASSWORD env var
#   2. Override CMD: ["node","openclaw.mjs","gateway","--allow-unconfigured","--bind","lan"]
CMD ["node", "openclaw.mjs", "gateway", "--allow-unconfigured"]
