# LabNow Open

[![License](https://img.shields.io/badge/License-BSD%203--Clause-green.svg)](https://opensource.org/licenses/BSD-3-Clause)
[![GitHub Workflow Status](https://img.shields.io/github/actions/workflow/status/LabNow-ai/labnow-open/build-docker.yml?branch=main)](https://github.com/LabNow-ai/labnow-open/actions)
[![Recent Code Update](https://img.shields.io/github/last-commit/LabNow-ai/labnow-open.svg)](https://github.com/LabNow-ai/labnow-open/commits)
[![Visit Images on Quay.io](https://img.shields.io/badge/Quay.io-Images-green)](https://quay.io/organization/labnow)
[![Visit Images on DockerHub](https://img.shields.io/badge/DockerHub-Images-green)](https://hub.docker.com/u/LabNow)

Please generously STAR★ our project or donate to us!
[![GitHub Stars](https://img.shields.io/github/stars/LabNow-ai/labnow-open.svg?label=Stars)](https://github.com/LabNow-ai/labnow-open/stargazers)

Discussion and contributions are welcome:
[![Join Discord Chat](https://img.shields.io/badge/Discuss_on-Discord-green)](https://discord.gg/kHUzgQxgbJ)
[![Open an Issue on GitHub](https://img.shields.io/github/issues/LabNow-ai/labnow-open)](https://github.com/LabNow-ai/labnow-open/issues)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/LabNow-ai/labnow-open)

---

`LabNow Open` 是一个开源的容器化 AI/Data 工作空间项目，目标是让你用尽可能少的环境配置，快速得到可用的研发环境与工具门户。

项目内置了一个轻量 Web Console，用于管理和跳转常用数据科学服务，包含：

- JupyterLab
- VS Code (code-server)
- RStudio Server
- Shiny Server

## 快速开始（直接使用现成镜像）

如果你只想快速体验，建议直接运行镜像：

```bash
docker run --rm -it \
  --name labnow-open \
  -p 8888:80 \
  quay.io/labnow/labnow-open-data-science:latest
```

启动后访问：`http://localhost:8888/`
