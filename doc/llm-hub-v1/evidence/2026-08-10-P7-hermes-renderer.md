# P7 Hermes renderer 本地证据

## 固定身份

- Phase base：`21019e0c24dc7b51747c2bef3cd90f5d259be839`
- Renderer commit：`b17e02cdcf752dd6a2177f21d5489f9698334221`
- 本轮容器兼容 commit：`8c56966c4b6be12702d4397aad6b1a153b87d053`
- 上述代码范围的 diff SHA-256：`2406ecb3e5a37d17ea2684e34a9b67ecd03b68e59cc22aaaffcc1fa0a0f0d7c5`
- 契约：`v1alpha1 / 0.1.0-rc.1`
- Hermes upstream：`https://github.com/Mushroom47/hermes-agent.git@1388cd1c0c1800078bfcc92aebd144fbf145fdb4`
- Hermes 基础镜像：`quay.io/labnow/hermes@sha256:c47cf16fad3fbb952a616c910fe3c7769e8516a15986db182752091e1ec02d67`
- Node build base：`quay.io/labnow/node@sha256:fd09d9de9b7aa927493acbafbb7d399c089465e988f2a6a240428cdbbd5424e2`
- 本地产品镜像：`quay.io/labnow/labnow-open:che-568-hermes-console-experience-local`
- 产品 image ID/RepoDigest：`sha256:56e69ace0da9dbede193e80904fa76ded1dd94cfc38cb1137f6df686c5b7f031`

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

## 零明文与清理

对 Git diff、产品镜像 Config、history、保存并展开的镜像层、Docker 进程参数执行不输出匹配正文的 credential 模式扫描。每个 scope 的前置命令退出 `0`，`rg` 扫描退出 `1`，`zero_hit=true`；关联测试容器数量为 `0`。临时扫描归档与所有测试目录均已删除。

测试只使用合成 fixture；本仓未记录真实 RuntimeSecretFile 路径、内容、Authorization header、模型响应或控制面凭证。没有推送镜像、发布或部署。
