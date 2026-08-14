# P8 / CHE-595：OpenClaw 命名 Workspace 控制台路径

## 交付边界

- Phase 分支：`dev/che-595-openclaw-named-workspace-basepath`
- Phase base：`629cfad25152e437d1cae85f0f96f8296ffa845b`
- 产品代码提交：`f9e2525416034e4a4b97f04d41caf91f0b5fe0b6`
- control/review policy commit：`bf4112873dfe89604f52ef8689e527fe43e08d46`
- 交付方式：`local_only`；未推送分支或镜像，未部署，未修改 `main` 或 `integration/llm-hub-v1`。

本次只修改 OpenClaw 启动边界与本仓回归测试。公共契约、Shell、Launcher、lab-dev 与 upstream
OpenClaw 均未修改。

## 已验证行为

`start-labnow-openclaw.sh` 将 `gateway.controlUi.basePath` 视为 LabNow 托管的运行时路由状态：
它从严格校验后的 `URL_PREFIX` 派生当前 Workspace 路径，以私有临时文件、`0600` 权限与原子
`mv` 收敛该字段。配置父目录、配置文件符号链接与相对/可疑前缀仍失败关闭。

容器回归以同一个挂载到 `/root/.openclaw/data` 的持久化 Home 依次验证：首次
`/user/workspace-a/`、切换到 `/user/workspace-b/`、重复 B、以及重新以 A 启动。每次均验证
OpenClaw Gateway、Caddy 路由与独立 CLI；B 的重复执行保留相同配置 SHA-256。用户 provider、
默认模型、Gateway mode 与既有 `tools.allow` 均被保留；非法相对 `URL_PREFIX` 返回 `64`。

## 本地镜像与验证

构建仅保留在本地，未推送或发布：

```text
quay.io/labnow/labnow-open-openclaw:che-595-named-workspace-basepath-local
image id / local RepoDigest: sha256:ba68033ace1ec61fb3982eb2380d07f086d0f46a21f68da094004dd8da0d3eee
base image: quay.io/labnow/openclaw@sha256:edc85cc2068f5ec0df470f7d06daa0a4fbd78ef5ad6cf5b48f58381da839dd12
```

执行结果（均为退出 `0`，除特别注明项）：

```bash
bash -n src/labnow-open-etc/start-labnow-openclaw.sh \
  tests/openclaw-product-closure-container-test.sh \
  tests/openclaw-model-access-adapter-test.sh \
  tests/openclaw-model-access-adapter-container-test.sh

docker build -q --platform linux/amd64 \
  -t quay.io/labnow/labnow-open-openclaw:che-595-named-workspace-basepath-local \
  -f src/labnow-open.Dockerfile \
  --build-arg BASE_NAMESPACE=quay.io \
  --build-arg BASE_IMG=labnow/openclaw@sha256:edc85cc2068f5ec0df470f7d06daa0a4fbd78ef5ad6cf5b48f58381da839dd12 \
  --build-arg PROFILE_LOCALIZE=default .

LOCAL_IMAGE=quay.io/labnow/labnow-open-openclaw:che-595-named-workspace-basepath-local \
  tests/openclaw-product-closure-container-test.sh

tests/openclaw-model-access-adapter-test.sh
tests/openclaw-model-access-adapter-container-test.sh
git diff --check
```

容器回归输出的非敏感断言：最终配置 SHA-256 为
`97a26306086f08256723148835ff0e6eec8a33c9a6662b757d06007132ef7f04`，重复 B 的配置 SHA-256 为
`3938929698544396bc5078e55ada4fa500072bd49028715b6818cb5fafac3209`，非法前缀退出 `64`。

## 凭证边界

本轮未读取 RuntimeSecretFile 或任何控制面凭证。对相对基线 diff、镜像 inspect、镜像 history 与
`docker image save` 产物执行不输出匹配正文的凭证模式扫描；四个范围均为 `scan_exit=1`、
`zero_hit=true`。扫描前置命令（`git diff`、inspect、history、image save）与 Caddy validate 均
退出 `0`。临时扫描产物已移入本机废纸篓，未加入仓库。

## 残余风险与交接

- S0/S1：未发现。
- S2：本地镜像只证明源码可重现和本机回归，不等同于发布镜像、镜像签名或生产部署。
- S3：真实多用户浏览器与跨仓生命周期仍应由总控使用固定组合复验。

交接状态：`ready_for_review`。
