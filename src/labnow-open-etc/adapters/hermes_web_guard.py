"""Open 自有的网页返回保护；不替换 Hermes Agent 的秘密解析器。"""
from __future__ import annotations

import functools
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import threading

POLICY_PATH = Path("/etc/labnow/managed-identity.json")
MANAGED_DIR = Path("/etc/hermes")
MAX_POLICY = 16 * 1024
MAX_ENV = 64 * 1024
MAX_CONFIG = 1024 * 1024
MAX_RESPONSE = 8 * 1024 * 1024
_REF = re.compile(r"\$\{([^}]+)}")


class GuardFailure(Exception):
    def __init__(self, status=503):
        self.status = status
        super().__init__({503: "平台身份网页保护配置不可用。", 403: "该网页操作涉及受管运行身份。", 413: "网页配置或响应超过保护上限。", 400: "网页配置参数不合法。"}[status])


def _trusted_read(path: Path, limit: int) -> bytes:
    """只读同一描述符；策略及其直接目录必须由 root 控制，禁止符号链接。"""
    try:
        parent = path.parent.lstat()
        if not stat.S_ISDIR(parent.st_mode) or parent.st_uid != 0 or parent.st_mode & 0o022:
            raise GuardFailure()
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        with os.fdopen(fd, "rb") as stream:
            before = os.fstat(stream.fileno())
            if not stat.S_ISREG(before.st_mode) or before.st_uid != 0 or before.st_mode & 0o022 or before.st_size > limit:
                raise GuardFailure()
            data = stream.read(limit + 1)
            after = os.fstat(stream.fileno())
            if len(data) > limit or (before.st_mtime_ns, before.st_size, before.st_ino, before.st_ctime_ns) != (after.st_mtime_ns, after.st_size, after.st_ino, after.st_ctime_ns):
                raise GuardFailure()
            return data
    except GuardFailure:
        raise
    except Exception:
        raise GuardFailure() from None


class PolicySource:
    def __init__(self, policy_path=POLICY_PATH, managed_dir=MANAGED_DIR):
        # 参数仅用于已核实的服务端装配/测试；install 默认固定系统路径，不读取用户 env。
        self.policy_path = Path(policy_path)
        self.managed_dir = Path(managed_dir)
        self._names = None
        self._required = False
        self._lock = threading.Lock()

    def snapshot(self, *, required=False):
        with self._lock:
            try:
                if self.policy_path.parent.is_symlink():
                    raise GuardFailure()
                self.policy_path.lstat()
                present = True
            except FileNotFoundError:
                present = False
            except Exception:
                self._required = True
                raise GuardFailure() from None
            if not self._required and not present:
                if required:
                    self._required = True
                    raise GuardFailure()
                # 系统秘密源中出现平台运行变量时，缺名单不能伪装为普通Lab。
                # 仅看固定管理员目录；不由用户.env或浏览器选择模式。
                env = self.managed_dir / ".env"
                try:
                    env.lstat()
                except FileNotFoundError:
                    return None
                except Exception:
                    self._required = True
                    raise GuardFailure() from None
                from agent.secret_scope import _parse_env_text
                try:
                    values = _parse_env_text(_trusted_read(env, MAX_ENV).decode("utf-8-sig"))
                    if any(n.startswith("LABNOW_RUN_") for n in values):
                        self._required = True
                        raise GuardFailure()
                except Exception:
                    self._required = True
                    raise GuardFailure() from None
                return None  # 普通 Lab；已有原生管理配置不等于平台托管模式。
            self._required = True
            encoded = _trusted_read(self.policy_path, MAX_POLICY)
            try:
                policy = json.loads(encoded)
                if not isinstance(policy, dict) or set(policy) != {"version", "protected_env"} or type(policy["version"]) is not int or policy["version"] != 1:
                    raise GuardFailure()
                names = policy["protected_env"]
                if not isinstance(names, list) or not 1 <= len(names) <= 8 or any(not isinstance(n, str) or not re.fullmatch(r"LABNOW_RUN_[A-Z0-9_]{1,64}", n) for n in names) or len(set(names)) != len(names):
                    raise GuardFailure()
                names = tuple(sorted(names))
                if self._names is not None and names != self._names:
                    raise GuardFailure()
                # 即使秘密源故障，启用状态也不退回普通 Lab。
                self._names = names
                from hermes_cli.managed_scope import get_managed_dir
                from agent.secret_scope import _parse_env_text
                if get_managed_dir() != self.managed_dir:
                    raise GuardFailure()
                env_bytes = _trusted_read(self.managed_dir / ".env", MAX_ENV)
                values = _parse_env_text(env_bytes.decode("utf-8-sig"))
                protected = tuple(values.get(n) for n in names)
                if any(not isinstance(v, str) or not re.fullmatch(r"[!-~]{16,4096}", v) or "${" in v for v in protected):
                    raise GuardFailure()
                admin = self.managed_dir / "config.yaml"
                admin_bytes = _trusted_read(admin, MAX_ENV) if admin.exists() or admin.is_symlink() else b""
                if admin_bytes:
                    from utils import fast_safe_load
                    check_references(fast_safe_load(admin_bytes.decode("utf-8-sig")), names)
                return names, protected, hashlib.sha256(encoded + b"\0" + env_bytes + b"\0" + admin_bytes).digest()
            except GuardFailure:
                raise
            except Exception:
                raise GuardFailure() from None


def check_references(value, names):
    """与固定原生环境引用语法一致；仅网页配置使用，不求值或下载任何引用。"""
    if isinstance(value, str):
        for ref in _REF.findall(value):
            ref = ref.strip()
            if ref.startswith("env:"):
                ref = ref[4:].strip()
            if ref in names:
                raise GuardFailure(403)
    elif isinstance(value, dict):
        for item in value.values():
            check_references(item, names)
    elif isinstance(value, list):
        for item in value:
            check_references(item, names)


def _contains_value(value, protected):
    if isinstance(value, str):
        return any(v in value for v in protected)
    if isinstance(value, dict):
        return any(_contains_value(k, protected) or _contains_value(v, protected) for k, v in value.items())
    if isinstance(value, list):
        return any(_contains_value(v, protected) for v in value)
    return False


def _config_surface(path):
    return path in {"/api/config", "/api/egress/status"} or path.startswith(("/api/config/", "/api/providers/"))


def _route_path(request):
    # 用已匹配的原生路由，不让编码字符或反向代理root_path改变保护分类。
    route = request.scope.get("route")
    return getattr(route, "path", request.scope.get("path", request.url.path))


async def _precheck(request, names, protected):
    path = _route_path(request)
    body = None
    if request.method in {"POST", "PUT", "PATCH", "DELETE"} and (_config_surface(path) or path.startswith("/api/env")):
        encoded = await request.body()
        if len(encoded) > MAX_CONFIG:
            raise GuardFailure(413)
        try:
            body = json.loads(encoded) if encoded else {}
        except Exception:
            raise GuardFailure(400) from None
        if not isinstance(body, dict):
            raise GuardFailure(400)
        check_references(body, names)
        if _contains_value(body, protected):
            raise GuardFailure(403)
        if path.startswith("/api/env") or path == "/api/providers/validate":
            if body.get("key") in names:
                raise GuardFailure(403)
    if _config_surface(path):
        profile = (body or {}).get("profile") or request.query_params.get("profile")
        if profile is not None and not isinstance(profile, str):
            raise GuardFailure(400)
        from starlette.concurrency import run_in_threadpool
        def read_raw():
            from hermes_cli.web_server_profiles import _config_profile_scope
            from hermes_cli.config import get_config_path, read_user_config_raw
            try:
                with _config_profile_scope(profile):
                    file = get_config_path()
                    if not file.is_file() or file.stat().st_size > MAX_CONFIG:
                        raise GuardFailure()
                    check_references(read_user_config_raw(), names)
            except GuardFailure:
                raise
            except Exception:
                raise GuardFailure() from None
        await run_in_threadpool(read_raw)


def guarded_handler(original, source):
    @functools.wraps(original)
    async def handle(request):
        from starlette.concurrency import run_in_threadpool
        from starlette.responses import JSONResponse
        from starlette.exceptions import HTTPException
        before = None
        try:
            before = await run_in_threadpool(source.snapshot)
            if before is None:
                return await original(request)
            names, protected, stamp = before
            await _precheck(request, names, protected)
            response = await original(request)
            after = await run_in_threadpool(source.snapshot, required=True)
            if after[2] != stamp:
                raise GuardFailure()  # 轮换/策略变更期间不释放旧快照结果。
            # 配置读取必须是可完整检查的响应，不能用流式配置导出绕过。
            data = getattr(response, "body", None)
            if data is None:
                if _config_surface(_route_path(request)) or _route_path(request).startswith("/api/env"):
                    raise GuardFailure()
                return response
            if len(data) > MAX_RESPONSE:
                raise GuardFailure(413)
            if any(v in str(response.raw_headers) for v in protected):
                raise GuardFailure(403)
            if "application/json" in response.headers.get("content-type", "").lower():
                try:
                    value = json.loads(data)
                except Exception:
                    raise GuardFailure() from None
                if _contains_value(value, protected):
                    raise GuardFailure(403)
                if _route_path(request) == "/api/env" and isinstance(value, dict):
                    value = {k: v for k, v in value.items() if k not in names}
                    response.body = json.dumps(value, ensure_ascii=False).encode()
                    response.headers["content-length"] = str(len(response.body))
            elif any(v.encode() in data for v in protected):
                raise GuardFailure(403)
            if _config_surface(_route_path(request)) or _route_path(request).startswith("/api/env"):
                response.headers["cache-control"] = "no-store"
            return response
        except GuardFailure as exc:
            return JSONResponse({"detail": str(exc)}, status_code=exc.status, headers={"cache-control": "no-store"})
        except HTTPException as exc:
            if before and (_contains_value(exc.detail, before[1]) or _contains_value(exc.headers or {}, before[1])):
                return JSONResponse({"detail": "该网页操作涉及受管运行身份。"}, status_code=403, headers={"cache-control": "no-store"})
            raise
        except Exception:
            if before is None:
                raise
            return JSONResponse({"detail": "平台身份网页保护读取失败。"}, status_code=503, headers={"cache-control": "no-store"})
    return handle


def install(app, source=None):
    """在原生鉴权中间件以内包装原始路由；不添加公开路由或替换秘密函数。"""
    from fastapi.routing import APIRoute, request_response
    if getattr(app.state, "labnow_managed_web_guard", False):
        return
    source = source or PolicySource()
    source.snapshot()  # 已配置但无效时，拒绝启动该网页入口。
    for route in app.routes:
        if isinstance(route, APIRoute):
            route.app = request_response(guarded_handler(route.get_route_handler(), source))
    app.state.labnow_managed_web_guard = True
