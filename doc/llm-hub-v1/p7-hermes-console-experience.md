# P7 Hermes 控制台体验（本仓记录）

## 范围与状态

- Phase：P7 / CHE-568；本仓仅负责 Hermes renderer 与既有 Hermes Console/Gateway/Caddy 入口的运行时接入。
- 交付方式：`local_only`；Linear 由总控维护，本仓不直接写入。
- 冻结基线：`integration/llm-hub-v1@06c49f26642c7e39a118aedad1395197f2bd91db`；Phase base：`21019e0c24dc7b51747c2bef3cd90f5d259be839`。
- 契约：`v1alpha1 / 0.1.0-rc.1`。不向公共契约新增 Hermes 私有字段。

## Hermes 受管边界

- 固定运行材料仍为 `/run/labnow/model-access/manifest.json`、`/run/labnow/model-access/secret.json`（`0400`）和 `/run/labnow/model-access/status.json`。
- `hermes-model-access-adapter` 只接受 `adapter_id: "hermes"` 的 RC1 `RuntimeManifest`，校验 manifest/secret 的 `binding_id`、`lease_id`、`generation` 一致后，输出 RC1 `RuntimeStatus`。
- Hermes 私有受管目录为 `/root/.hermes/labnow-model-access`；只写入 `config.yaml` 与 `state/binding.json`，不会修改用户拥有的 `/root/.hermes/config.yaml` 或 `/root/.hermes/.env`。
- 受管配置格式来自 Hermes 上游的 managed-scope overlay 语义：`HERMES_MANAGED_DIR` 下的 `config.yaml` 按叶子覆盖用户配置。配置只保存 `${OPENAI_API_KEY}` 引用，启动包装器在受管配置存在时从固定 Secret 文件读取并仅在进程环境中传递实际 key；不写入配置、状态、日志、镜像层或进程参数。
- Adapter 声明 `supports_reload: false`；generation 变更使用受控重启，包装器重新读取当前挂载的 `RuntimeSecretFile`。`remove` 仅删除 Hermes 私有受管配置和状态，不撤销 LiteLLM key。

## 已有产品入口

Docker 镜像保留既有 Hermes Gateway、Dashboard、Caddy readiness 路由与 Console 跳转；Supervisor 改由
`start-labnow-hermes.sh` 启动 Gateway/Dashboard，以便其与 Adapter 共享 `HERMES_MANAGED_DIR`。

## 本地验证入口

不含真实凭证的合成 fixture 验证：

```bash
bash -n src/labnow-open-etc/hermes-model-access-adapter.sh \
  src/labnow-open-etc/start-labnow-hermes.sh \
  tests/hermes-model-access-adapter-test.sh \
  tests/hermes-model-access-adapter-container-test.sh
bash tests/hermes-model-access-adapter-test.sh
```

固定基础镜像到位后，容器验证只接受不可变完整引用：

```bash
HERMES_IMAGE=quay.io/labnow/hermes@sha256:<digest> \
  bash tests/hermes-model-access-adapter-container-test.sh
```

历史 `quay.io/labnow/hermes:local` 仅用于确认上游配置格式，不能作为 P7 镜像、容器或真实 smoke 证据。最终本地产品镜像会使用 `quay.io/labnow/labnow-open:che-568-hermes-console-experience-local`，只在收到 Dev 固定的 Hermes 基础 digest 后构建；不推送、不发布、不部署。

## 待完成的固定组合验证

当前等待 Dev 提供 Hermes 上游 commit、不可变基础镜像 digest 与本地可复查来源。取得后需要重建本地产品镜像，运行固定基础镜像 container test、产品容器回归及受影响真实黄金链；证据只记录脱敏摘要、镜像/报告 hash 与清理结果。
