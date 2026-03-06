# LabNow Open

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

启动后访问：

`http://localhost:8888/`
