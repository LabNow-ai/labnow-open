"""固定Lark入口仅改用OpenClaw公开core子路径，不重开整个SDK根导出。"""
from pathlib import Path
import hashlib
import json
import subprocess

PLUGIN = Path("/opt/openclaw/plugins/openclaw-lark")
EXPECTED_SHA256 = "6ec125dbb842cba0c8be02a8fc6e1d2d3faf138b97f6e91bd2af525e0f8f2a7a"
OLD = 'require("openclaw/plugin-sdk")'
NEW = 'require("openclaw/plugin-sdk/core")'


def verify_sdk(plugin):
    package = Path("/opt/openclaw/node_modules/openclaw/package.json")
    value = json.loads(package.read_text())
    if value.get("version") != "2026.9.8" or "./plugin-sdk/core" not in value.get("exports", {}):
        raise RuntimeError("OpenClaw公开SDK版本未核实，停止插件兼容装配。")
    probe = "const {createRequire}=require('node:module');const r=createRequire(process.argv[1]);if(typeof r('openclaw/plugin-sdk/core').emptyPluginConfigSchema!=='function')throw Error('public core contract missing');"
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
    check_sdk(plugin)
    target.write_text(restored.replace(OLD, NEW))
    print("固定Lark入口已改用公开core SDK；插件及配置保留。")
    return True


if __name__ == "__main__":
    install()
