/** 仅在隔离的固定 Hermes 验证制品中运行；复用原生依赖，不安装包。 */
import { copyFileSync, existsSync, unlinkSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const root = process.env.HERMES_SOURCE_ROOT || "/opt/hermes";
const test = root + "/web/src/components/LabnowSidecarOwnedRegression.test.tsx";
const config = root + "/web/labnow.sidecar-test.config.mjs";
if (existsSync(test) || existsSync(config))
  throw new Error("隔离测试文件已存在，拒绝覆盖。");
const baseline = process.env.LABNOW_HERMES_RECONNECT_BASELINE === "true";
try {
  copyFileSync(
    fileURLToPath(
      new URL("./test_hermes_sidecar_reconnect.tsx", import.meta.url),
    ),
    test,
  );
  writeFileSync(
    config,
    `import { mergeConfig } from 'vitest/config';
import upstream from './vitest.config.ts';
import { sidecarReconnectPlugin } from './labnow.sidecar-reconnect.mjs';
export default mergeConfig(upstream, { plugins: ${baseline ? "[]" : "[sidecarReconnectPlugin()]"} });
`,
  );
  const args = [
    root + "/node_modules/vitest/vitest.mjs",
    "run",
    "--config",
    config,
  ];
  if (baseline) args.push("-t", "历史会话切换后");
  const result = spawnSync(process.execPath, args, {
    cwd: root + "/web",
    stdio: "inherit",
    env: { ...process.env, NODE_ENV: "development" },
  });
  if (result.error) throw result.error;
  process.exitCode = result.status ?? 1;
} finally {
  if (existsSync(test)) unlinkSync(test);
  if (existsSync(config)) unlinkSync(config);
}
