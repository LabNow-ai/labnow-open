# LabNow Open

[![License](https://img.shields.io/badge/License-BSD%203--Clause-green.svg)](https://opensource.org/licenses/BSD-3-Clause)
[![GitHub Workflow Status](https://img.shields.io/github/actions/workflow/status/LabNow-ai/labnow-open/build-docker.yml?branch=main)](https://github.com/LabNow-ai/labnow-open/actions)
[![Recent Code Update](https://img.shields.io/github/last-commit/LabNow-ai/labnow-open.svg)](https://github.com/LabNow-ai/labnow-open/commits)
[![Visit Images on Quay.io](https://img.shields.io/badge/Quay.io-Images-green)](https://quay.io/organization/labnow)
[![Visit Images on DockerHub](https://img.shields.io/badge/DockerHub-Images-green)](https://hub.docker.com/u/LabNow)

Please generously STAR⭐️ our project or donate to us!
[![GitHub Stars](https://img.shields.io/github/stars/LabNow-ai/labnow-open.svg?label=Stars)](https://github.com/LabNow-ai/labnow-open/stargazers)

Discussion and contributions are welcome:
[![Join Discord Chat](https://img.shields.io/badge/Discuss_on-Discord-green)](https://discord.gg/kHUzgQxgbJ)
[![Open an Issue on GitHub](https://img.shields.io/github/issues/LabNow-ai/labnow-open)](https://github.com/LabNow-ai/labnow-open/issues)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/LabNow-ai/labnow-open)

> 中文文档：[doc/README-cn.md](doc/README-cn.md)

---

LabNow Open is an open-source, containerized AI/data science workspace. It bundles a lightweight **Web Console** that lets you manage and launch common data science services — all from a single browser tab, with minimal setup.

## What's Included

- **JupyterLab** — interactive notebooks and data exploration
- **VS Code** (code-server) — full-featured code editor in the browser
- **RStudio Server** — R development environment
- **Shiny Server** — interactive R web applications
- **Hermes** — gateway and dashboard for AI tool orchestration
- **OpenClaw** — AI agent platform

All services run behind a unified **Caddy** reverse proxy on port 80, managed by **supervisord** for process lifecycle control.

## Image Variants

All variants are built from a single [Dockerfile](src/labnow-open.Dockerfile) and differ only in which base image they layer on top of:

| Image Tag | Base Image | What It Contains |
|---|---|---|
| `labnow-open-dev` | `developer:latest` | Minimal dev tools + Web Console |
| `labnow-open-data-science` | `data-science-dev:latest` | Full data science stack (Python, R, Jupyter) |
| `labnow-open-hermes` | `hermes:latest` | Hermes gateway + dashboard |
| `labnow-open-openclaw` | `openclaw:latest` | OpenClaw AI agent platform |

Images are published on both [Quay.io](https://quay.io/organization/labnow) and [Docker Hub](https://hub.docker.com/u/LabNow).

## Quick Start

Run the full data science variant with a single command:

```bash
docker run --rm -it \
  --name labnow-open \
  -p 8888:80 \
  quay.io/labnow/labnow-open-data-science:latest
```

Then open **http://localhost:8888/** in your browser. The Web Console will show all available services — click any card to launch it.

### Other Variants

```bash
# Minimal developer image
docker run --rm -it -p 8888:80 quay.io/labnow/labnow-open-dev:latest

# With Hermes gateway
docker run --rm -it -p 8888:80 quay.io/labnow/labnow-open-hermes:latest

# With OpenClaw agent platform
docker run --rm -it -p 8888:80 quay.io/labnow/labnow-open-openclaw:latest
```


### Hermes 的 Lab 路径前缀构建

固定 Hermes 版本的原生服务会按 `X-Forwarded-Prefix` 改写 HTML/CSS 并注入 `__HERMES_BASE_PATH__`。原构建中的懒加载 JS/CSS 仍指向站点根目录，不能用根目录公开静态资源绕过 Workspace 鉴权。

Hermes 镜像构建通过 `src/labnow-open-etc/adapters/build_hermes_web.py` 核对原生配置摘要与 Vite 8.2.0，再加载 `hermes_vite_prefix.config.mjs` 重建。仅 JS 引用使用原生运行时前缀；HTML/CSS 保留原生改写。未知版本停止构建，不安装新依赖、不修改用户配置、Casdoor 或 LiteLLM。

在构建后的 Hermes 镜像运行 `node /source/tool/tests/test_hermes_web_prefix.mjs` 可核对实际 Vite 配置的8种路径合同；仍需通过受保护的完整 Lab 路径验收聊天页及真实对话，不能用构建成功代替浏览器验证。


Hermes 的Python3.13运行镜像还须按原生源码声明补齐 `websockets==15.0.1`。仅有Uvicorn并不证明支持WebSocket：没有协议实现时`AutoWebSocketsProtocol=None`，Dashboard Upgrade会被当作普通HTTP处理。`requirements-workspace-hermes.txt`及安装后的原生协议检测固定这一合同；`tool/tests/test_hermes_cli.py`会进行真实回环升级和消息收发，验证缺依赖的镜像失败、完整镜像通过，不调用模型。
