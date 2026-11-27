"""固定Lark制品使用已核实的公开SDK与原生CommonJS模块定位。"""
from pathlib import Path
import hashlib
import json
import subprocess

PLUGIN = Path("/opt/openclaw/plugins/openclaw-lark")
EXPECTED_SHA256 = "6ec125dbb842cba0c8be02a8fc6e1d2d3faf138b97f6e91bd2af525e0f8f2a7a"
OLD = 'require("openclaw/plugin-sdk")'
NEW = 'require("openclaw/plugin-sdk/core")'


# 固定制品两处模块定位和一处公开SDK导入；全部预检后才写入。
MODULE_FIXES = {
    "src/card/reply-dispatcher.js": (
        "c9b411f1353f14343f6cc456146dec3ade3d7e280ce3b6e42149ec3c1e01c62b",
        'require("openclaw/plugin-sdk/channel-runtime")',
        'require("openclaw/plugin-sdk/channel-reply-pipeline")',
    ),
    "src/core/version.js": (
        "643f7c2e54abeca541afcdf3e487c3b2cc9309e5b2850e076aece7dd5fd4261d",
        "        const __filename = (0, node_url_1.fileURLToPath)(import.meta.url);\n        const __dirname = (0, node_path_1.dirname)(__filename);",
        "        // 固定CommonJS制品使用Node原生__dirname定位包文件。",
    ),
    "src/core/token-store.js": (
        "ec08e378a6ddf132aa68017316f7426a82d5ce7ff203771541d825ba5006f92c",
        "const _require = (0, node_module_1.createRequire)(typeof __filename !== 'undefined' ? __filename : import.meta.url);",
        "const _require = (0, node_module_1.createRequire)(__filename);",
    ),
}


def verify_sdk(plugin):
    package = Path("/opt/openclaw/node_modules/openclaw/package.json")
    value = json.loads(package.read_text())
    if value.get("version") != "2026.9.8" or not {"./plugin-sdk/core", "./plugin-sdk/channel-reply-pipeline"}.issubset(value.get("exports", {})):
        raise RuntimeError("OpenClaw公开SDK版本未核实，停止插件兼容装配。")
    probe = "const {createRequire}=require('node:module');const r=createRequire(process.argv[1]);const core=r('openclaw/plugin-sdk/core'),pipeline=r('openclaw/plugin-sdk/channel-reply-pipeline');if(typeof core.emptyPluginConfigSchema!=='function'||typeof pipeline.createReplyPrefixContext!=='function'||typeof pipeline.createTypingCallbacks!=='function')throw Error('public plugin contract missing');"
    subprocess.run(["node", "-e", probe, str(plugin / "package.json")], check=True)


def install(plugin=PLUGIN, *, check_sdk=verify_sdk):
    plugin = Path(plugin)
    if not plugin.exists():
        return False
    value = json.loads((plugin / "package.json").read_text())
    if value.get("name") != "@larksuite/openclaw-lark" or value.get("version") != "2026.7.16":
        raise RuntimeError("Lark插件版本未核实，停止兼容装配。")
    target = plugin / "index.js"
    source = target.read_text()
    restored = source.replace(NEW, OLD)
    if hashlib.sha256(restored.encode()).hexdigest() != EXPECTED_SHA256 or restored.count(OLD) != 1:
        raise RuntimeError("Lark插件入口摘要不匹配，停止兼容装配。")
    prepared = [(target, restored.replace(OLD, NEW))]
    for relative, (digest, original, replacement) in MODULE_FIXES.items():
        file = plugin / relative
        content = file.read_text().replace(replacement, original)
        if hashlib.sha256(content.encode()).hexdigest() != digest or content.count(original) != 1:
            raise RuntimeError("Lark兼容源码摘要不匹配，停止兼容装配。")
        prepared.append((file, content.replace(original, replacement)))
    check_sdk(plugin)
    for file, content in prepared:
        file.write_text(content)
    print("固定Lark公开SDK和CommonJS定位已兼容；插件及配置保留。")
    return True


if __name__ == "__main__":
    install()
