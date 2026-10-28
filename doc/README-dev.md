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

## OpenClaw 平台运行身份的管理接口保护

OpenClaw 变体构建时，`install_openclaw_guard.py` 校验实际命令 shim、2026.9.8 软件包和三份原生源码的精确摘要，将 Open 自有保护接入 `secrets.resolve` 的结果出口。固定镜像内全局 CLI 和项目 CLI 两份副本均安装；未知版本或已有不同适配停止构建。原生 Gateway 鉴权、scope、Agent 内部秘密解析和 `secrets.reload` 不替换。

托管启动必须设置仅由可信启动控制的 `LABNOW_RUN_MANAGED=1`，并准备直接父目录 root 所有、无组/其他写权限、非符号链接的两个固定系统文件：

- `/etc/labnow/openclaw-managed-identity.json`：文件须由 root 所有，内容为`{"version":1,"protected_env":["LABNOW_RUN_API_KEY"]}`。
- `/etc/labnow/openclaw-runtime-identity.json`：按原生 FileProvider 合同，文件须属于进程有效 UID、权限 `0400` 或 `0600`，仅包含名单对应的运行身份字段；实际值由可信启动写入，不放入镜像、构建参数、网页配置或日志。

通过 root 控制的只读目录挂载提供 `/etc/labnow`；适配会依据已打开文件描述符的内核 mount id 核实该目录挂载为只读，不能只凭文件属主放行。可信控制端在目录内原子替换身份文件，不能采用固定单文件 bind 挂载后假设替换会自动可见。OpenClaw 原生 FileProvider 指向固定身份 JSON，并以相应 JSON pointer 引用；实际格式、签发和刷新属于 Console/Launcher 接线，不能用 Provider 长期 Key 代替运行身份。

适配在每次管理回读前后重读系统策略，结合原生未解析配置、原生 SecretRef 识别和活跃快照定位受管引用。按来源路径拒绝回读，防止身份文件已更新而原生缓存仍保留旧值时漏出旧身份；文件别名和局部 JSON pointer 同样受保护。原生错误、diagnostics 和返回值另检查请求内已知受管值，不持久保存值副本。策略/来源消失、不可读、名单改变、快照无法分类或请求期间轮换时失败关闭。普通未绑定 Lab 保持原生行为，自持 Key 的合法读取与原生刷新继续可用。

这层保护针对管理接口，不替代 Console 逐请求授权，也不承诺容器所有者/终端隔离、任意编码识别或完整 Agent 接线。运行身份采用用户已确认的最长 300 秒、Launcher 每 60 秒更新；产品签发与刷新是否已完成以 Governance 阶段验收为准，不能根据镜像含适配文件推定已接通。

在实际开发容器运行：

```bash
node --test tool/tests/openclaw_web_guard.test.mjs
python3 -m unittest discover -s tool/tests -v
```

Node 用例使用真实临时文件验证 root 所有权，要求在开发容器执行。单元测试不证明原生浏览器权限和快照合同；还需使用固定原生 CLI、真实 Control UI 和合成身份进行正反向验证。

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


## 个人 Workspace 平台模型消费者

新合同为 `personal-workspace-v1`，镜像默认不启用。构建时显式设置
`WORKSPACE_IDENTITY_ADAPTER=hermes` 或 `openclaw`；装配器核实固定原生启动脚本后写入能力标签，
Launcher 仍须核对主目录允许的镜像别名、不可变 image ID 与标签。其他镜像的 adapter 标签为空，不能用于本合同。
本仓保留多阶段 Dockerfile、原有前端和启动方式；运行配置复制移到前端构建之后以复用缓存。

原生配置只保存 `labnow-runtime` 静态标记。真正模型请求发送前，Python HTTPX 事件钩子或 Node fetch 适配
从只读系统目录 `/etc/labnow` 读取当前运行身份，固定 HTTPS Console 目标与 models/chat 路径，直接使用规范尾斜线，
拒绝重定向、SDK重放和不可用身份。原生SDK即使缓存配置，也不能固定使用旧身份；自持 Key 和普通配置保留。
Console 每次仍核验当前 Casdoor、活跃实例及资源权限，镜像文件不能替代服务端授权。

Launcher 提供 root 控制的 `workspace-model.json`、`openclaw-managed-identity.json` 及0400身份文件，目录只读挂载；
Hermes另有只读 `/etc/hermes` 原生 managed 配置。身份最长300秒，每60秒更新；失败不延长期限。
Hermes构建以实际命令shebang定位Python，补齐固定上游声明的 `openai==2.24.0`，安装进该解释器的 `.pth`，
不在运行时下载依赖。OpenClaw通过Launcher的固定 `NODE_OPTIONS --import` 在SDK加载前装配发送适配。
启动装配只在 `LABNOW_RUN_MANAGED=1` 时执行，healthcheck不读取身份；不覆盖自持同名provider冲突。

开发环境验证入口：

```bash
node --test tool/tests/*.test.mjs
python3 -B -m unittest discover -s tool/tests -v
```

Hermes原生镜像使用其CLI实际解释器执行Python入口，并要求所有SDK用例运行、无跳过。
OpenClaw原生镜像通过已校验的 `install_openclaw_guard.package_for_entry()` 定位真实软件包，
设置测试变量 `NATIVE_OPENCLAW_PACKAGE_JSON` 为其 `package.json` 后执行Node入口；该变量仅供测试。
普通开发容器缺少原生依赖时明确跳过，不作为真实调用证据。
新镜像、原生SDK自动化及配置校验仍不能替代真实Launcher创建、Console签发、模型调用和停止/撤权验收。


### OpenClaw 原生dispatcher通道

固定2026.9.8的原生guard在使用DNS钉扎dispatcher时会选择独立Undici实现，单独替换全局fetch不能覆盖模型出口。
`install_openclaw_transport.py` 在全局/项目两份原生CLI中接入已有 `fetchImpl` 槽，仅对托管身份启用，
保留原生SSRF/DNS钉扎/dispatcher、代理、TLS及截止；显式限制0次redirect。适配发送URL和新的init，
保留dispatcher与取消信号，真实短期JWT不写回原始SDK参数或原生捕获器。三个固定依赖SHA改变时停止构建。
普通模式和自持Key使用原guard选项；未把生产fetch伪装成测试mock，也未关闭原生SSRF。
Hermes另有真实Agent与真实SDK的离线发送自动化，低层响应为合成SSE，不作真实Console/Provider验收。
Agent自身任务恢复可能发起独立请求，每次仍需Console当前授权/预算；不承诺所有Agent/Provider全局exactly-once。
