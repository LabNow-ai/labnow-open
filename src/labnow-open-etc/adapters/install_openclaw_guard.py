"""仅对已核实的原生OpenClaw入口和源码安装自有管理接口保护。"""
from pathlib import Path
import hashlib
import json
import shutil

ENTRY_TARGETS = {
    "25df56532827d328d582660a146fc9bf7356ba5fe93ba6f664e44effffafb305": "../.pnpm/openclaw@2026.9.8/node_modules/openclaw/openclaw.mjs",
    "4baae9a30d58ce2bfbc00cb9192dcb5e84f4a07df661e9381a6ab5e362f3fd08": "/opt/node/pnpm/global/v11/926ea0a51a5e60b563a5c9f5e53c1fda01ec614676ee4355740d8c425a806cdb/node_modules/openclaw/openclaw.mjs",
}
EXPECTED = {
    "secrets-CDMMk0N2.mjs": "4194d33456200c37ebe49ce7701f2e0915f3f7f054cdb9e98f6337b65a9313fd",
    "runtime-state-I0A0iuwu.mjs": "d1f4b6e8c3b8c22beff5c2910f9afa52dfeee25020c919bdeb076616778888f3",
    "types.secrets-BXEuin38.mjs": "4aff25056315741a510cbeef35251dbbad45db131656c5c78db51ce4398f3826",
}
IMPORT = ('import { wrapSecretsHandlers as _labnowWrapSecretsHandlers } from "./labnow_openclaw_guard.mjs";\n'
          'import { a as _labnowCoerceSecretRef } from "./types.secrets-BXEuin38.mjs";\n')
START = "function createSecretsHandlers(params) {\n\treturn {"
PATCHED_START = "function createSecretsHandlers(params) {\n\treturn _labnowWrapSecretsHandlers({"
END = "\t};\n}\n//#endregion\nexport { createSecretStoreWriteService, createSecretsHandlers };"
PATCHED_END = ("\t}, { snapshot: getActiveSecretsRuntimeSnapshotState, coerceRef: _labnowCoerceSecretRef });\n"
               "}\n//#endregion\nexport { createSecretStoreWriteService, createSecretsHandlers };")


def package_for_entry(entry):
    entry = entry.resolve(strict=True)
    raw = entry.read_bytes()
    target = ENTRY_TARGETS.get(hashlib.sha256(raw).hexdigest())
    if target is None or raw.decode().splitlines()[-1] != "# cmd-shim-target=" + target:
        raise RuntimeError("OpenClaw命令入口版本不匹配，停止安装。")
    root = (entry.parent / target).resolve(strict=True).parent
    if json.loads((root / "package.json").read_text()).get("version") != "2026.9.8":
        raise RuntimeError("OpenClaw软件包版本不匹配，停止安装。")
    return root


def install(root, adapter):
    dist = root / "dist"
    target = dist / "secrets-CDMMk0N2.mjs"
    source = target.read_text()
    restored = source.removeprefix(IMPORT).replace(PATCHED_START, START).replace(PATCHED_END, END)
    if hashlib.sha256(restored.encode()).hexdigest() != EXPECTED[target.name]:
        raise RuntimeError("OpenClaw秘密接口源码版本不匹配，停止安装。")
    for name, digest in EXPECTED.items():
        if name != target.name and hashlib.sha256((dist / name).read_bytes()).hexdigest() != digest:
            raise RuntimeError("OpenClaw秘密接口依赖版本不匹配，停止安装。")
    if restored.count(START) != 1 or restored.count(END) != 1:
        raise RuntimeError("OpenClaw秘密接口装配结构不匹配。")
    patched = IMPORT + restored.replace(START, PATCHED_START).replace(END, PATCHED_END)
    dest = dist / "labnow_openclaw_guard.mjs"
    raw = adapter.read_bytes()
    if dest.exists() and dest.read_bytes() != raw:
        raise RuntimeError("已有不同的OpenClaw保护适配，停止覆盖。")
    if not dest.exists():
        shutil.copyfile(adapter, dest)
        dest.chmod(0o444)
    target.write_text(patched)
    print("OpenClaw平台运行身份管理接口保护已安装；托管启动仍须核实系统策略。")


if __name__ == "__main__":
    command = shutil.which("openclaw")
    if command is None:
        raise RuntimeError("OpenClaw命令不存在。")
    # 固定镜像同时包含全局和项目级CLI；两处均保护，不能只补测试使用的副本。
    entries = [Path(command), Path("/opt/openclaw/node_modules/.bin/openclaw")]
    roots = {package_for_entry(entry) for entry in entries if entry.exists()}
    for root in sorted(roots):
        install(root, Path(__file__).with_name("openclaw_web_guard.mjs"))
