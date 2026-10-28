"""仅配置平台模型的静态标记，不将真实运行JWT复制到原生应用配置。"""
from __future__ import annotations

import json
import os
from pathlib import Path
import stat
import sys
import tempfile
from urllib.parse import urlsplit

from workspace_transport import WorkspaceSource, SENTINEL, WorkspaceTransportError


def description(source, adapter):
    # 配置来源不是授权。启动UI不依赖JWT尚有余额/有效期；真实发送另行完整核验。
    _, policy = source._read("openclaw-managed-identity.json")
    if policy != {"version": 1, "protected_env": ["LABNOW_RUN_TOKEN"]}:
        raise WorkspaceTransportError()
    _, value = source._read("workspace-model.json")
    if (not isinstance(value, dict) or set(value) != {"version", "adapter_id", "base_url", "model", "expires_at"}
            or type(value["version"]) is not int or value["version"] != 1
            or value["adapter_id"] != adapter or value["model"] != "labnow-managed" or type(value["expires_at"]) is not int):
        raise WorkspaceTransportError()
    target = urlsplit(value["base_url"])
    if (target.scheme != "https" or not target.hostname or target.username or target.password or target.query or target.fragment
            or target.path.rstrip("/") != "/console/api/token/runtime/v1"):
        raise WorkspaceTransportError()
    return value


def _dictionary(parent, key):
    value = parent.setdefault(key, {})
    if not isinstance(value, dict):
        raise WorkspaceTransportError()
    return value


def bootstrap(adapter, *, source=None, config_path=None):
    if os.environ.get("LABNOW_RUN_MANAGED") != "1":
        return False
    if adapter not in {"hermes", "openclaw"}:
        raise WorkspaceTransportError()
    source = source or WorkspaceSource(adapter=adapter)
    current = description(source, adapter)
    if adapter == "hermes":
        # Launcher产生只读的原生managed配置；不覆盖用户配置或自定义provider列表。
        path = Path(config_path or "/etc/hermes/config.yaml")
        config = json.loads(path.read_text())
        expected = {"provider": "custom", "default": "labnow-managed", "base_url": current["base_url"], "api_mode": "chat_completions", "api_key": SENTINEL}
        if not isinstance(config, dict) or config.get("model") != expected:
            raise WorkspaceTransportError()
        return True
    value = config_path or os.environ.get("OPENCLAW_CONFIG_PATH", "")
    if not value or not Path(value).is_absolute():
        raise WorkspaceTransportError()
    path = Path(value)
    if path.is_symlink():
        raise WorkspaceTransportError()
    previous = path.read_bytes()  # 原生bootstrap/update_config已运行，保留其网关/插件配置。
    config = json.loads(previous)
    if not isinstance(config, dict):
        raise WorkspaceTransportError()
    models = _dictionary(config, "models")
    models.setdefault("mode", "merge")
    providers = _dictionary(models, "providers")
    reserved = "labnow-managed"
    existing = providers.get(reserved)
    if existing is not None and (not isinstance(existing, dict) or existing.get("apiKey") != SENTINEL):
        raise WorkspaceTransportError()  # 不覆盖碰巧同名的自持Key。
    providers[reserved] = {
        "baseUrl": current["base_url"], "apiKey": SENTINEL, "api": "openai-completions",
        "models": [{"id": "labnow-managed", "name": "平台模型", "reasoning": False,
                    "input": ["text"], "contextWindow": 16384, "maxTokens": 4096}],
    }
    defaults = _dictionary(_dictionary(config, "agents"), "defaults")
    selected = defaults.get("model")
    if isinstance(selected, str) or selected is None:
        selected = {};defaults["model"] = selected
    if not isinstance(selected, dict):
        raise WorkspaceTransportError()
    selected["primary"] = reserved + "/labnow-managed"
    encoded = (json.dumps(config, ensure_ascii=False, indent=2) + "\n").encode()
    if path.read_bytes() != previous:
        raise WorkspaceTransportError()
    fd, temporary = tempfile.mkstemp(prefix=path.name + ".labnow-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(encoded);stream.flush();os.fchmod(stream.fileno(), 0o600);os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)
    return True


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2:
            raise WorkspaceTransportError()
        bootstrap(sys.argv[1])
    except Exception:
        print("平台模型配置未就绪，已停止托管启动。", file=sys.stderr)
        raise SystemExit(1) from None
