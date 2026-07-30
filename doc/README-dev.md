# Development Guide

## Architecture

```
Browser (:80)
    │
    v
┌──────────────────────────────────────────────┐
│  Caddy (reverse proxy)                        │
│  Serves static Console UI + routes traffic    │
│  /home/*     → supervisord RPC (:9001)         │
│  /lab/*      → JupyterLab     (:8888)         │
│  /vscode/*   → code-server    (:9999)         │
│  /rserver/*  → RStudio Server (:8787)         │
│  /rshiny/*   → Shiny Server   (:3838)         │
│  /hermes/*   → Hermes Dashboard (:9119)        │
│  /openclaw/* → OpenClaw       (:18789)        │
└──────────────────────────────────────────────┘
    │
    v
┌──────────────────────────────────────────────┐
│  supervisord (process manager)                │
│  Auto-detects available tools and manages     │
│  their start/stop/restart lifecycle           │
└──────────────────────────────────────────────┘
    │
    v
┌──────────────────────────────────────────────┐
│  React SPA (Web Console)                      │
│  Carbon Design System, Vite 8, React 19       │
│  Card-based UI for service management         │
└──────────────────────────────────────────────┘
```

## Project Structure

```
labnow-open/
├── src/
│   ├── labnow-open.Dockerfile    # Multi-stage build (builder + runtime)
│   ├── labnow-open-web/          # React 19 + Vite + Carbon Design System
│   │   ├── src/App.jsx           # Console UI with service card grid
│   │   ├── src/api/              # supervisord REST API client
│   │   ├── src/hooks/            # React hooks for state management
│   │   └── public/               # Static assets and logos
│   └── labnow-open-etc/          # Runtime configuration
│       ├── supervisord.conf      # Process manager configuration
│       ├── Caddyfile             # Reverse proxy routes
│       └── CaddyRoutes/          # Per-service route snippets
├── tool/
│   ├── tool.sh                   # CI helper: build/push Docker images
│   └── cicd/                     # Dev & staging Docker Compose files
└── .github/workflows/
    └── build-docker.yml          # CI/CD: semgrep SAST, multi-variant builds
```

## Getting Started

### Method 1: Using run-dev.sh (Recommended)

Start the development container and enter into it:

```bash
./tool/cicd/run-dev.sh up
./tool/cicd/run-dev.sh enter
```

### Method 2: Manual Docker Run

```bash
docker run -d \
    --name dev-labnow-open \
    -p 8888:80 -p 3000:3000 \
    -v $(pwd):/root/ \
    quay.io/labnow/data-science-dev \
    tail -f /dev/null

docker exec -it dev-labnow-open bash
```

## Running the App in Dev Mode

Inside the container, link configs and start services:

```bash
mkdir -pv /etc/supervisord && ln -sf /root/src/labnow-open-etc/supervisord.conf /etc/supervisord/
mkdir -pv /etc/caddy       && ln -sf /root/src/labnow-open-etc/Caddyfile        /etc/caddy/
export STATIC_DIR=/root/src/labnow-open-web/dist && start-supervisord.sh
```

Then access: **http://localhost:8888/**

## Standalone Frontend Development

Develop the React frontend independently (without Docker):

```bash
cd src/labnow-open-web
pnpm install
pnpm run dev        # Dev server on http://localhost:3000
pnpm run build      # Production build to dist/
```

In dev mode, Vite proxies `/api` requests to `localhost:80`, so you can run the frontend standalone against a running backend.

## Building Docker Images Locally

```bash
docker build -t labnow-open-dev:latest \
  -f src/labnow-open.Dockerfile \
  --build-arg PROFILE_LOCALIZE=aliyun-pub .
```

Run the built image:

```bash
docker run --rm -it \
    --name dev-labnow-open \
    -p 8080:80 \
    labnow-open-dev:latest
```

## CI/CD

On push to `main`, pull requests, tag releases (`v*`), and weekly schedules, GitHub Actions:

1. Runs **semgrep SAST** (static analysis security testing)
2. Builds all four image variants in parallel
3. Pushes to `quay.io/labnow/` and `docker.io/labnow/`
4. Optionally syncs to a mirror registry

See [.github/workflows/build-docker.yml](../.github/workflows/build-docker.yml) for details.

### Image Variants

All variants are built from a single [Dockerfile](../src/labnow-open.Dockerfile) and differ only in which base image they layer on top of:

| Image Tag | Base Image | What It Contains |
|---|---|---|
| `labnow-open-dev` | `developer:latest` | Minimal dev tools + Web Console |
| `labnow-open-data-science` | `data-science-dev:latest` | Full data science stack (Python, R, Jupyter) |
| `labnow-open-hermes` | `hermes:latest` | Hermes gateway + dashboard |
| `labnow-open-openclaw` | `openclaw:latest` | OpenClaw AI agent platform |
