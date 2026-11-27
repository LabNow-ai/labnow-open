"""设置原生Control UI挂载路径；路径不是用户授权或模型身份来源。"""
from pathlib import Path
import json
import os
import re
import stat
import tempfile
from urllib.parse import unquote, urlsplit


def control_ui_path(prefix):
    if not isinstance(prefix, str) or not prefix.startswith("/") or re.search(r"[\\\x00-\x20\x7f?#]", prefix):
        raise RuntimeError("OpenClaw网页路径前缀不合法。")
    url = urlsplit(prefix)
    if url.netloc or url.scheme:
        raise RuntimeError("OpenClaw网页路径前缀不合法。")
    for part in prefix.split("/"):
        decoded = unquote(part, errors="strict")
        if decoded in (".", "..") or re.search(r"[/\\%\x00-\x20\x7f]", decoded):
            raise RuntimeError("OpenClaw网页路径前缀不合法。")
    return prefix.rstrip("/") + "/openclaw"


def configure(path, prefix):
    target = Path(path)
    base_path = control_ui_path(prefix)
    if target.is_symlink():
        raise RuntimeError("OpenClaw网页配置不能是符号链接。")
    try:
        original = target.read_text()
        value = json.loads(original)
        if not isinstance(value, dict):
            raise ValueError()
        gateway = value.setdefault("gateway", {})
        if not isinstance(gateway, dict):
            raise ValueError()
        ui = gateway.setdefault("controlUi", {})
        if not isinstance(ui, dict):
            raise ValueError()
    except (ValueError, TypeError, OSError):
        raise RuntimeError("OpenClaw网页配置不合法。") from None
    if ui.get("basePath") == base_path:
        return
    ui["basePath"] = base_path
    mode = stat.S_IMODE(target.stat().st_mode)
    name = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", dir=target.parent, prefix=".web-config-", delete=False) as output:
            name = output.name
            os.fchmod(output.fileno(), mode)
            json.dump(value, output, ensure_ascii=False, indent=2)
            output.write("\n")
        os.replace(name, target)
    finally:
        if name and Path(name).exists():
            Path(name).unlink()


if __name__ == "__main__":
    path = os.environ.get("OPENCLAW_CONFIG_PATH")
    if not path:
        raise SystemExit("未配置OpenClaw原生配置路径。")
    configure(path, os.environ.get("URL_PREFIX", "/"))
