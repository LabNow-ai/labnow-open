# P7 Hermes renderer 本地证据

## 固定身份

- Phase base：`21019e0c24dc7b51747c2bef3cd90f5d259be839`
- Renderer commit：`b17e02cdcf752dd6a2177f21d5489f9698334221`
- 本轮容器兼容 commit：`8c56966c4b6be12702d4397aad6b1a153b87d053`
- 租约毫秒时间戳兼容 commit：`2ac4e268d562c7d26ace8affc830f09cf1cb9305`
- 契约：`v1alpha1 / 0.1.0-rc.1`
- Hermes upstream：`https://github.com/Mushroom47/hermes-agent.git@1388cd1c0c1800078bfcc92aebd144fbf145fdb4`
- Hermes 基础镜像：`quay.io/labnow/hermes@sha256:c47cf16fad3fbb952a616c910fe3c7769e8516a15986db182752091e1ec02d67`
- Node build base：`quay.io/labnow/node@sha256:fd09d9de9b7aa927493acbafbb7d399c089465e988f2a6a240428cdbbd5424e2`
- 本地产品镜像：`quay.io/labnow/labnow-open:che-568-hermes-console-experience-local`
- 产品 image ID/RepoDigest：`sha256:b80bca4bfedbab67f6d14855509cc119aeeb212f25e4ce19a5738d7c53ba4d27`

## 脱敏验证

| 命令 | 结果 |
| --- | --- |
| `bash -n`（Hermes Adapter、包装器及四个 Hermes 测试） | 退出 `0` |
| `bash tests/hermes-model-access-adapter-test.sh` | 退出 `0`；RC1 valid/invalid、0400、identity、幂等、generation 2、用户配置与 remove 通过 |
| `bash tests/start-labnow-hermes-test.sh` | 退出 `0`；受管配置时仅向子进程注入 key，非受管时不读取 Secret |
| `HERMES_IMAGE=quay.io/labnow/hermes@sha256:… bash tests/hermes-model-access-adapter-container-test.sh` | 退出 `0`；固定基础镜像中 apply/probe、generation 2、remove 与零落盘通过 |
| `LOCAL_IMAGE=quay.io/labnow/labnow-open:che-568-hermes-console-experience-local bash tests/hermes-console-experience-container-test.sh` | 退出 `0`；镜像内 Adapter hash、私有受管目录、真实 `hermes config check`、包装器、受控重启、remove 通过 |
| `OPENCLAW_IMAGE=quay.io/labnow/openclaw@sha256:edc… bash tests/openclaw-model-access-adapter-container-test.sh` | 退出 `0`；P6 Adapter 回归通过 |
| `pnpm --dir src/labnow-open-web run build` | 退出 `0` |
| `git diff --check` | 退出 `0` |

## P7-R2 直接影响复验

真实 Shell 会按 `Date.toISOString()` 生成带毫秒的 RC1 `expires_at`。固定镜像内
`jq fromdateiso8601` 只接受秒级 `Z` 时间，导致第一轮真实链在 Workspace 内以
`INVALID_MANIFEST` 失败。`2ac4e268d562c7d26ace8affc830f09cf1cb9305`
仅在校验前移除合法的 `Z` 毫秒部分，并把宿主机 fixture 改为
`2099-01-01T00:00:00.123Z`；公共 schema、字段和租约语义均未改变。

修复后的本地产品镜像绑定 `io.labnow.product.revision=2ac4e268…` 与固定 Hermes
基础 digest。镜像内 Adapter hash 与该提交源码一致，宿主机、固定 Hermes base
container 和产品镜像 container 回归全部退出 `0`。

Dev 参数化黄金链 run `p7-c2d3e4f5a60718293a4b5c6d7e8f9012` 随后使用本镜像
通过实际 Hermes model、stream、terminal tool、usage、generation 2、旧 key
拒绝、revoke/delete、零活跃 lease、敏感扫描与资源清理。脱敏聚合报告
SHA-256 为 `1d4331b482dd6959efba7707f991c79bf0076cf46ff2b8f7813c31de862d1a61`，
产品报告 SHA-256 为
`de08555b73a3d2229d1047931c1dd3ef97b38cd1f62fa1d1c219dcdba95567ed`。

## 零明文与清理

对 Git diff、产品镜像 Config、history、保存并展开的镜像层、Docker 进程参数执行不输出匹配正文的 credential 模式扫描。每个 scope 的前置命令退出 `0`，`rg` 扫描退出 `1`，`zero_hit=true`；关联测试容器数量为 `0`。临时扫描归档与所有测试目录均已删除。

测试只使用合成 fixture；本仓未记录真实 RuntimeSecretFile 路径、内容、Authorization header、模型响应或控制面凭证。没有推送镜像、发布或部署。
