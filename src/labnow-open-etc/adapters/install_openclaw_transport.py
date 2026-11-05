"""在固定OpenClaw自有镜像中接通原生dispatcher-aware模型出口。"""
from pathlib import Path
import hashlib
import shutil
from install_openclaw_guard import package_for_entry

EXPECTED = {
    "provider-transport-fetch-B_VndpTk.mjs": "947e3a5600a44eec76d5445d6ffa825a4d2c971ec0abf741159b5c0643a9a090",
    "fetch-guard-BulPh3pN.mjs": "d9f7abf4a07e6420b892c827f20a92939f2490f46ad6ad396029f5e40813d089",
    "runtime-fetch-DkWhaX5J.mjs": "d18e488c8e2e588c7766976d31779f0b3206814c5c25548c7517dba91344a92e",
}
IMPORT = ('import { workspaceGuardedFetchOptions as _labnowWorkspaceFetchOptions } from "/opt/labnow-open/etc/adapters/workspace_transport.mjs";\n'
          'import { n as _labnowRuntimeFetch } from "./runtime-fetch-DkWhaX5J.mjs";\n')
ORIGINAL = "result = await fetchWithSsrFGuard(useEnvProxy ? withTrustedEnvProxyGuardedFetchMode(guardedFetchOptions) : guardedFetchOptions);"
PATCHED = "result = await fetchWithSsrFGuard(_labnowWorkspaceFetchOptions(useEnvProxy ? withTrustedEnvProxyGuardedFetchMode(guardedFetchOptions) : guardedFetchOptions, _labnowRuntimeFetch));"


def prepare(root):
    dist = Path(root) / "dist"
    target = dist / "provider-transport-fetch-B_VndpTk.mjs"
    source = target.read_text()
    restored = source.removeprefix(IMPORT).replace(PATCHED, ORIGINAL)
    if hashlib.sha256(restored.encode()).hexdigest() != EXPECTED[target.name] or restored.count(ORIGINAL) != 1:
        raise RuntimeError("OpenClaw原生模型出口版本不匹配，停止装配。")
    for name, digest in EXPECTED.items():
        if name != target.name and hashlib.sha256((dist / name).read_bytes()).hexdigest() != digest:
            raise RuntimeError("OpenClaw原生传输依赖版本不匹配，停止装配。")
    return target, IMPORT + restored.replace(ORIGINAL, PATCHED)


def install(roots):
    # 先核验两份实际CLI，避免只装配测试使用的一份。
    prepared = [prepare(root) for root in roots]
    for target, source in prepared: target.write_text(source)
    print("OpenClaw原生模型传输槽已接通；SSRF、DNS钉扎和TLS保持。")


if __name__ == "__main__":
    command = shutil.which("openclaw")
    if command is None: raise RuntimeError("原生OpenClaw命令不存在。")
    entries = [Path(command), Path("/opt/openclaw/node_modules/.bin/openclaw")]
    roots = sorted({package_for_entry(path) for path in entries if path.exists()})
    install(roots)
