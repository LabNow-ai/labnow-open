# P6 OpenClaw 产品闭环（本仓记录）

## 状态

- Phase：P6 / CHE-563
- 本仓状态：开发中；仅完成本地产品入口、路由和镜像级验证。
- Linear：由总控独占写入；本仓未修改 Linear。
- 交付方式：`local_only`；未推送分支、镜像或部署。

## 冻结输入

- control/review policy commit：`2eb71d7590739df3de8db2f8cf9098154a397f0b`
- Phase base：`dfac9767fd6cdd4706ac4cd6917defcafd1c6eb8`
- 契约：`v1alpha1 / 0.1.0-rc.1`
- RC1 bundle SHA-256：`d289dff9bcaa3d28035c5ed2e56b806f4b3b37fdca3159352d22f0c03942e202`
- 固定 OpenClaw 基镜像：`quay.io/labnow/openclaw@sha256:edc85cc2068f5ec0df470f7d06daa0a4fbd78ef5ad6cf5b48f58381da839dd12`

## 本仓差异

- 将 OpenClaw CLI/Gateway/Adapter 的 `OPENCLAW_CONFIG` 与 `OPENCLAW_CONFIG_PATH` 对齐到
  `/root/.openclaw/data/openclaw.json`。
- 增加 `start-labnow-openclaw.sh`：仅设置缺失的 `gateway.controlUi.basePath`，保留已有用户 provider、agent 默认模型和 Gateway 设置；冲突路径失败关闭，不覆盖用户选择。
- 新 Workspace 缺失 `tools.allow` 时只启用 P6 冻结工具 smoke 所需的 `exec`；已有用户工具白名单保持不变，避免默认暴露的额外工具让固定 smoke 漂移为非目标工具链。
- Supervisor 启动实际存在的 OpenClaw Gateway 脚本，并固定 loopback `18789` 与 `autostart=true`。
- 增加 `${URL_PREFIX}openclaw/` 的 Caddy 代理和 `${URL_PREFIX}api` readiness 代理；OpenClaw 保留完整 workspace 前缀以匹配 Control UI base path。
- Console 增加 `openclaw` 程序卡片和 `/openclaw/` 跳转。
- `probe` 向 OpenClaw CLI 显式传递其已解析的 `OPENCLAW_CONFIG_PATH`，使镜像只
  预设 `OPENCLAW_CONFIG` 时仍验证与 `apply` 相同的受管配置。
- 独立 Adapter 容器回归刻意以 `env -u OPENCLAW_CONFIG_PATH` 调用 Adapter，仍确认
  `probe` 通过，避免镜像环境变量掩盖路径传递问题。

未改变 RC1 公共字段、RuntimeManifest/RuntimeSecretFile/RuntimeStatus 固定路径、Adapter 动作集合或模型受管命名空间；未引入 Hermes。

## 本地验证

以下命令在 Phase 工作树运行，均未传入真实 RuntimeSecretFile：

```bash
bash -n src/labnow-open-etc/openclaw-model-access-adapter.sh \
  src/labnow-open-etc/start-labnow-openclaw.sh \
  tests/openclaw-model-access-adapter-test.sh \
  tests/openclaw-model-access-adapter-container-test.sh \
  tests/openclaw-product-closure-container-test.sh

OPENCLAW_IMAGE=quay.io/labnow/openclaw@sha256:edc85cc2068f5ec0df470f7d06daa0a4fbd78ef5ad6cf5b48f58381da839dd12 \
  bash tests/openclaw-model-access-adapter-container-test.sh

LOCAL_IMAGE=quay.io/labnow/labnow-open:che-563-openclaw-product-closure-local \
  bash tests/openclaw-product-closure-container-test.sh
```

结果：Adapter host/container 回归通过；本地镜像中的 OpenClaw Supervisor 为 Running，独立
OpenClaw CLI 继承固定的配置路径且 `config validate` 通过，`/user/p6/openclaw/` 与
`/user/p6/api` 均返回 `200`；用户 provider/default model/Gateway mode 保留，Control UI
base path 为 `/user/p6/openclaw`，新 Workspace 默认工具白名单为 `exec`。

本地镜像仅构建未推送：

```text
quay.io/labnow/labnow-open:che-563-openclaw-product-closure-local
image id: sha256:c9c6a45637521cbbaeacea57fbb128696066fd91c5dff4521555f1bd5211f244
```

失败关闭验证：相对 `URL_PREFIX` 退出 `64`；冲突的 `gateway.controlUi.basePath` 退出 `72`；Caddy validate 退出 `0`。

## 安全与待完成验证

- 本次 diff、镜像层、镜像 Config 与 P6 临时容器残留均执行了不输出匹配正文的 credential pattern 扫描，结果零命中；扫描命令退出码分别为 `1`、`1`、`1`，临时容器残留为零。
- 本地构建与测试没有使用、记录或保留 RuntimeSecretFile、模型 key、Authorization header 或控制面凭证。
- P6-MUST-03/04/07/08 的真实跨仓 claim→apply/probe→activate、chat/stream/tool、撤销/清理和聚合证据仍须由 `lab-dev` 黄金 runner 使用本轮短期运行材料完成。材料只能经挂载文件或环境安全传递，本仓不得记录其路径或内容。
