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

## 配置生成静态验证

在已有开发环境、仓库根目录执行，无需安装额外依赖：

```bash
python3 -B -m unittest discover -s tool/tests -p 'test_*.py' -v
```

测试从 Dockerfile 提取配置生成片段，在临时目录中执行；命令可用性由替身控制，不调用真实应用。覆盖 Hermes/Selkies 有无组合、仓库模板与代表性继承配置的保持、路由处理及其他程序配置。构建提示只输出日志，不得追加到 `supervisord.conf`。

这项验证不构建镜像或启动服务，标准 INI 解析通过也不等于 supervisor 完整语义、继承镜像或真实 Hermes 启动已通过。修改后仍需另行核验新制品。

## Hermes 平台运行身份的网页保护

`src/labnow-open-etc/adapters/` 是 Open 自有适配层。Hermes 变体构建时，安装器先核对六份固定原生源码的 SHA-256 和路由装配 AST，再将保护接入原生网页路由；未知版本停止构建，不静默跳过。其他变体没有 `hermes` 命令时不安装此适配。它不新增服务、数据库或公开 API，不修改原生 Agent 的秘密读取与刷新函数。

普通 Lab 没有系统策略、固定管理员秘密源中也没有平台运行变量时，保持原路由响应。托管启动必须准备只读系统文件 `/etc/labnow/managed-identity.json`：

```json
{"version": 1, "protected_env": ["LABNOW_RUN_API_KEY"]}
```

名单只能包含 1–8 个 `LABNOW_RUN_*` 变量，不是身份格式或 TTL 的选择。实际运行身份只由可信启动写入 `/etc/hermes/.env`，不通过浏览器表单或用户 `.env` 注入。系统文件及直接父目录须由 root 控制、无组/其他用户写权限、非符号链接，并以只读挂载供应用读取；不得把真实值写入日志、文档或构建参数。不要用同名 Provider 长期 Key 代替 Console 专用运行身份。

固定管理员秘密源中已有平台变量而缺少名单时，网页入口拒绝启动。策略启用后，名单/秘密源缺失、不可读、改变受管变量集合或请求期间发生轮换均失败关闭；故障恢复后仍保护该变量，不退回普通模式。未来可信启动在签发/注入身份前还必须调用 `PolicySource().snapshot(required=True)` 核验此保护前提，不能单凭镜像存在适配文件就放行。

保护运行在原生鉴权之后，保留配置 `key_env` 指针和用户自持 Key。受管变量的网页 reveal/写入拒绝，配置中的 `${VAR}` / `${env:VAR}` 在展开前拒绝，返回值及错误详情再检查本请求内已知受管值。配置读取支持当前及命名 profile；普通配置和自持 Key 的读取、写入、轮换保持。配置/环境响应使用 `no-store`。

系统策略最多 16KiB、管理员秘密源 64KiB、网页配置正文 1MiB、可检查的响应 8MiB。该保护不读取 LiteLLM Credential、不授权模型调用，也不承诺任意编码识别、WebSocket/任意流式结果或生产日志全面脱敏。终端/容器所有者边界保持；真实 Console 运行身份、绑定、SDK刷新及 Agent 端到端必须另外验收。

测试命令仍为上文 `unittest discover`。普通开发环境缺少 Hermes/FastAPI 时，原生组合用例会明确 skip；必须在固定运行依赖中执行这些用例，并以真实登录/配置 HTTP 验证，不能用 skip 或鉴权夹具证明原生鉴权支持。

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
