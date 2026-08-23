# LabNow Open

[![License](https://img.shields.io/badge/License-BSD%203--Clause-green.svg)](https://opensource.org/licenses/BSD-3-Clause)
[![GitHub Workflow Status](https://img.shields.io/github/actions/workflow/status/LabNow-ai/labnow-open/build-docker.yml?branch=main)](https://github.com/LabNow-ai/labnow-open/actions)
[![GitHub Stars](https://img.shields.io/github/stars/LabNow-ai/labnow-open.svg?label=Stars)](https://github.com/LabNow-ai/labnow-open/stargazers)

> English docs: [README.md](../README.md)

---

`LabNow Open` 是一个开源的容器化 AI/数据科学工作空间项目。目标是让你用尽可能少的环境配置，快速得到可用的研发环境与统一工具门户。

项目内置一个轻量 **Web Console**（React SPA），通过卡片式界面管理和跳转常用数据科学服务。所有服务由 **Caddy** 统一反向代理，由 **supervisord** 负责进程生命周期管理。

## 集成的服务

| 服务 | 说明 | Web 路径 |
|---|---|---|
| **JupyterLab** | 交互式 Notebook 与数据探索 | `/lab/` |
| **VS Code** (code-server) | 浏览器中的完整代码编辑器 | `/vscode/` |
| **RStudio Server** | R 语言开发环境 | `/rserver/` |
| **Shiny Server** | R Shiny 交互式 Web 应用 | `/rshiny/` |
| **Hermes** | AI 工具网关与仪表盘 | `/hermes/` |
| **OpenClaw** | AI Agent 平台 | `/openclaw/` |


## 镜像变体

所有变体由同一个 [Dockerfile](../src/labnow-open.Dockerfile) 构建，区别仅在于所基于的基础镜像不同：

| 镜像标签 | 基础镜像 | 包含内容 |
|---|---|---|
| `labnow-open-dev` | `developer:latest` | 精简开发工具 + Web Console |
| `labnow-open-data-science` | `data-science-dev:latest` | 完整数据科学栈（Python, R, Jupyter） |
| `labnow-open-hermes` | `hermes:latest` | Hermes 网关 + 仪表盘 |
| `labnow-open-openclaw` | `openclaw:latest` | OpenClaw AI Agent 平台 |

镜像发布在 [Quay.io](https://quay.io/organization/labnow) 和 [Docker Hub](https://hub.docker.com/u/LabNow)。

## 快速开始

一条命令启动完整数据科学环境：

```bash
docker run --rm -it \
  --name labnow-open \
  -p 8888:80 \
  quay.io/labnow/labnow-open-data-science:latest
```

浏览器访问 **http://localhost:8888/**，Web Console 会列出所有可用服务，点击卡片即可启动。

### 其他变体

```bash
# 精简开发者镜像
docker run --rm -it -p 8888:80 quay.io/labnow/labnow-open-dev:latest

# 带 Hermes 网关
docker run --rm -it -p 8888:80 quay.io/labnow/labnow-open-hermes:latest

# 带 OpenClaw Agent 平台
docker run --rm -it -p 8888:80 quay.io/labnow/labnow-open-openclaw:latest
```


## 开发与 CI/CD

详细的本地开发指南与 CI/CD 流程说明见：[doc/README-dev.md](README-dev.md)

## 参与贡献

欢迎提交 Issue 和 Pull Request，也可以通过以下方式参与讨论：

- [![Join Discord Chat](https://img.shields.io/badge/Discuss_on-Discord-green)](https://discord.gg/kHUzgQxgbJ)
- [![Open an Issue](https://img.shields.io/github/issues/LabNow-ai/labnow-open)](https://github.com/LabNow-ai/labnow-open/issues)
