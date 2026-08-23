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
