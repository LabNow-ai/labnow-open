"""在已核实的原生脚本上装配Open自有消费者；未知输入拒绝构建。"""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import sys

SCRIPTS = {
    "openclaw": ("/usr/local/bin/start-openclaw.sh", "a1ea00d3a4a3b6199c742d3ef887f3bb905f5966e6d4c3ec1eaa3065efde4dac", "\nupdate_config\n"),
    "hermes": ("/usr/local/bin/start-hermes.sh", "8a5f484db34901852b336e330fa53776559ada4baeaa4376fe2678d0f1c66c02", "set -eu\n"),
}


# Caddy 与原生 Gateway 在同一容器，仅信任实际回环上游；浏览器身份仍由Console核实。
OPENCLAW_PROXY_OLD = "default_proxies='[\"0.0.0.0/0\",\"::/0\"]'"
OPENCLAW_PROXY_NEW = "default_proxies='[\"127.0.0.1/32\",\"::1/128\"]'"


OPENCLAW_CADDY_MATCH_OLD = "@path_user_openclaw path {$URL_PREFIX:}openclaw/*"
OPENCLAW_CADDY_MATCH_NEW = "@path_user_openclaw path {$URL_PREFIX:}openclaw {$URL_PREFIX:}openclaw/*"
OPENCLAW_CADDY_SHA256 = '628abf4c794a76e515c687924480c867afab229083996f5c96a01ba408f4f448'
OPENCLAW_CADDY_OLD = '    uri strip_prefix {$URL_PREFIX:}openclaw\n'
OPENCLAW_CADDY_NEW = '    # 原生Control UI配置同一basePath，保留完整Workspace路径。\n'


def _hermes_python():
    command = shutil.which("hermes")
    if command is None:
        raise RuntimeError("原生Hermes命令不存在。")
    interpreter = Path(command).read_text().splitlines()[0].removeprefix("#!").strip()
    if not interpreter.startswith("/") or " " in interpreter:
        raise RuntimeError("原生Hermes解释器入口不匹配。")
    return interpreter


def prepare_sdk(adapter, directory):
    if adapter != "hermes":
        return
    # 固定源码声明来自当前已校验的原生镜像。上游版本变化必须重新核实。
    manifest = Path("/opt/hermes/pyproject.toml").read_text()
    if any(dependency not in manifest for dependency in ['"openai==2.24.0;', '"prompt_toolkit==3.0.52;', '"snowballstemmer==3.1.1;', '"websockets==15.0.1;']):
        raise RuntimeError("原生Hermes SDK声明变化，停止自动装配。")
    interpreter = _hermes_python()
    subprocess.run([interpreter, "-m", "pip", "install", "--disable-pip-version-check", "--no-cache-dir",
                    "-r", str(Path(directory) / "requirements-workspace-hermes.txt")], check=True)
    subprocess.run([interpreter, "-c", "import openai,httpx,prompt_toolkit,snowballstemmer,websockets,ptyprocess; assert ptyprocess.__version__ == '0.7.0'; from uvicorn.protocols.websockets.auto import AutoWebSocketsProtocol; assert AutoWebSocketsProtocol is not None; assert websockets.__version__ == '15.0.1'; from importlib.metadata import version; assert version('snowballstemmer') == '3.1.1'; assert openai.__version__ == '2.24.0' and prompt_toolkit.__version__ == '3.0.52'"], check=True)


def install(adapter, *, directory=None, script_path=None, purelibs=None, caddy_route=None):
    if adapter not in SCRIPTS:
        raise RuntimeError("平台模型镜像adapter未明确配置。")
    directory = Path(directory or Path(__file__).parent)
    name, expected, marker = SCRIPTS[adapter]
    target = Path(script_path or name).resolve(strict=True)
    injection = ("\nif [ \"${LABNOW_RUN_MANAGED:-}\" = \"1\" ] && [ \"${1:-}\" != \"healthcheck\" ]; then\n"
                 "    python3 /opt/labnow-open/etc/adapters/workspace_bootstrap.py " + adapter + "\nfi\n")
    runtime_injection = injection
    if adapter == "openclaw":
        injection = "\npython3 /opt/labnow-open/etc/adapters/openclaw_web_config.py\n" + injection
    source = target.read_text()
    restored = source.replace(marker + injection, marker).replace(marker + runtime_injection, marker)
    if adapter == "openclaw":
        restored = restored.replace(OPENCLAW_PROXY_NEW, OPENCLAW_PROXY_OLD)
    if hashlib.sha256(restored.encode()).hexdigest() != expected or restored.count(marker) != 1:
        raise RuntimeError("原生Agent启动脚本版本不匹配，停止装配。")
    for file in ["workspace_bootstrap.py", "workspace_transport.py", "workspace_transport.mjs", "openclaw_web_guard.mjs"]:
        if not (directory / file).is_file():
            raise RuntimeError("平台模型镜像适配源不完整。")
    route = None
    if adapter == "openclaw":
        if not (directory / "openclaw_web_config.py").is_file():
            raise RuntimeError("OpenClaw网页配置适配缺失。")
        route = Path(caddy_route or directory.parent / "CaddyRoutes/openclaw.caddy")
        route_source = route.read_text().replace(OPENCLAW_CADDY_NEW, OPENCLAW_CADDY_OLD).replace(OPENCLAW_CADDY_MATCH_NEW, OPENCLAW_CADDY_MATCH_OLD)
        if hashlib.sha256(route_source.encode()).hexdigest() != OPENCLAW_CADDY_SHA256 or route_source.count(OPENCLAW_CADDY_OLD) != 1:
            raise RuntimeError("OpenClaw Caddy路由版本不匹配，停止装配。")
        subprocess.run([sys.executable, str(directory / "install_openclaw_plugin_compat.py")], check=True)
        subprocess.run([sys.executable, str(directory / "install_openclaw_transport.py")], check=True)
    if adapter == "hermes":
        if purelibs is None:
            interpreter = _hermes_python()
            purelibs = {subprocess.check_output([interpreter, "-c", "import sysconfig;print(sysconfig.get_paths()['purelib'])"], text=True).strip()}
        encoded = 'import os,runpy; os.environ.get("LABNOW_RUN_MANAGED") == "1" and runpy.run_path("/opt/labnow-open/etc/adapters/workspace_transport.py",run_name="__labnow_install__")\n'
        for purelib in purelibs:
            entry = Path(purelib) / "labnow_workspace_identity.pth"
            if entry.exists() and entry.read_text() != encoded:
                raise RuntimeError("已有不同的Python平台传输装配，停止覆盖。")
            entry.write_text(encoded);entry.chmod(0o444)
    patched = restored.replace(marker, marker + injection)
    if adapter == "openclaw":
        if patched.count(OPENCLAW_PROXY_OLD) != 1:
            raise RuntimeError("OpenClaw原生可信代理声明不匹配，停止装配。")
        patched = patched.replace(OPENCLAW_PROXY_OLD, OPENCLAW_PROXY_NEW)
    target.write_text(patched)
    if route is not None:
        route.write_text(route_source.replace(OPENCLAW_CADDY_OLD, OPENCLAW_CADDY_NEW).replace(OPENCLAW_CADDY_MATCH_OLD, OPENCLAW_CADDY_MATCH_NEW))
    print("平台模型消费者已装配；真实身份仍仅在系统文件和发送请求中使用。")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("需明确指定平台模型adapter。")
    prepare_sdk(sys.argv[1], Path(__file__).parent)
    install(sys.argv[1])
