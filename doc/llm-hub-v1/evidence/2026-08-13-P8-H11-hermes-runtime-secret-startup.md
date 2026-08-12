# P8-H11 Hermes Runtime Secret 冷启动本仓证据

## 交付身份与边界

- Linear：`CHE-589`；状态与评论由总控维护，本仓未直接写入 Linear。
- 冻结基线：`integration/llm-hub-v1@2f08bb9b8ad54e528878347a84972e91d6842fff`。
- Phase base：`18b20aa7fa3e506b9c85b88736c9f51f317d55d8`。
- Phase branch：`dev/che-589-hermes-runtime-secret-startup`。
- 本轮代码 commit：`f9b315af576c147041cc9dd741b77b8966d28bb7`；父提交为准确 Phase base。
- 契约：`v1alpha1 / 0.1.0-rc.1`；本轮没有修改公共字段、Shell、Launcher、LiteLLM 或其他仓库。
- 代码差异 SHA-256：`9f67f7ed22bc4b57275bdea53018b5184dc0d8f62b32bb7b3b390771695ac6b9`。

本轮只修复 Hermes 受管运行时的冷启动顺序：包装器先在有限窗口内发现固定
`RuntimeManifest`。发现 `adapter_id: hermes` 后，必须等待固定 Secret、私有受管
配置与 `state/binding.json` 的 `binding_id`、`lease_id`、`generation` 与 Manifest
一致，才向 Hermes 子进程环境注入 key。未发现 Manifest 时仍按非受管模式启动；发现
Hermes Manifest 后材料超时、路径不安全或身份不一致时以非零退出失败关闭，供既有
Supervisor 重启策略处理。错误信息只含稳定错误码，不含输入值或凭证。

## 修改文件

- `src/labnow-open-etc/start-labnow-hermes.sh`
  - 以 Manifest 而非已渲染配置作为受管启动触发条件；使用 10 秒发现窗口和 30 秒受管材料等待上限。
  - 在导出 `OPENAI_API_KEY` 前校验 0400 Secret、受管配置 SecretRef 及绑定状态的同代身份。
  - 仅 `exec` 前向 Hermes 子进程环境传递 key；不写入普通配置、状态、日志或命令参数。
- `tests/start-labnow-hermes-test.sh`
  - 覆盖 Gateway、Dashboard、TUI 的受管启动，冷启动延迟材料、同代状态、受管超时失败关闭、后续重启恢复和无 Manifest 的非受管路径。
- `tests/hermes-console-experience-container-test.sh`
  - 除已有 Adapter hash 外，增加产品镜像内 Hermes 启动包装器与当前源码 SHA-256 一致性断言。

## 固定本地镜像

- 基础镜像：`quay.io/labnow/hermes@sha256:c47cf16fad3fbb952a616c910fe3c7769e8516a15986db182752091e1ec02d67`。
- 本地产品镜像：`quay.io/labnow/labnow-open:che-589-hermes-runtime-secret-startup-local`。
- 产品镜像 image ID / 本地 RepoDigest：`sha256:193e36bbb07bd4fafac3d4cbcc3813a7232794169966990323560d73d4047fd9`。
- 仅本地构建；未推送镜像、未发布、未部署。

## 脱敏验证结果

| 命令 | 退出码 | 已验证事实 |
| --- | ---: | --- |
| `bash -n`（Hermes Adapter、启动包装器与四个 Hermes 测试） | `0` | Shell 语法有效。 |
| `bash tests/hermes-model-access-adapter-test.sh` | `0` | RC1 valid/invalid、0400、身份一致性、幂等、generation 轮换、用户配置保留及 remove 回归。 |
| `bash tests/start-labnow-hermes-test.sh` | `0` | 三个消费者经同一包装器获得受管环境；冷启动等待、超时失败关闭、重启恢复和非受管路径通过。 |
| `HERMES_IMAGE=quay.io/labnow/hermes@sha256:… bash tests/hermes-model-access-adapter-container-test.sh` | `0` | 固定 Hermes 基础镜像内 Adapter apply/probe、generation 2 和 remove 通过。 |
| `docker build --platform linux/amd64 …` | `0` | 用固定 Hermes digest 构建本地产品镜像。 |
| `LOCAL_IMAGE=quay.io/labnow/labnow-open:che-589-hermes-runtime-secret-startup-local bash tests/hermes-console-experience-container-test.sh` | `0` | 镜像内 Adapter/启动包装器源码 hash 一致，受管启动、generation 2、remove 与用户配置保留通过。 |
| `git diff --check` | `0` | 无空白错误。 |

credential 模式扫描不回显匹配内容：Git 差异、产品镜像 `inspect/history` 和 `docker image save`
导出层均得到 `command_exit=0`、`scan_exit=1`、`zero_hit=true`。临时扫描归档已移出
临时目录；没有将 Secret、Authorization header、虚拟 key 或控制面凭证写入本仓。

## 已验证、待总控验证与风险

- 已验证：本仓启动边界不会在已识别 Hermes 受管运行时时带着字面量 `${OPENAI_API_KEY}` 启动；只有当前 Manifest/Secret/受管状态同代一致才启动。
- 已验证：无 Manifest 的非受管 Workspace 不读取也不等待 Secret；受管材料未就绪不会无限等待，并以 `RUNTIME_MATERIAL_TIMEOUT` 失败关闭。
- 待总控固定组合验证：新建 Workspace 中 Gateway、Dashboard、TUI 进程变量存在性（仅布尔值）及 Dashboard Chat 首条非空消息。这是 P8-H11 的真实浏览器验证，不能由 HTTP 200、进程存在或 Secret 文件存在替代。
- S0：本仓静态、合成和容器验证未发现。
- S1：本仓已修复的冷启动时序无剩余已知 S1；真实浏览器闭环尚待总控复验，若失败应按冻结 P8-H11 规则重新定级。

## Handoff

`ready_for_review`：本仓最小修复、容器回归与零明文扫描完成；等待总控以固定跨仓组合执行真实 Dashboard 首条消息验证和最终复审。
