"""Open自有平台模型传输：配置只保留静态标记，真实运行身份在发送前读取。"""
from __future__ import annotations

import base64
from dataclasses import dataclass, field
from functools import wraps
import json
import os
from pathlib import Path
import re
import stat
import time
from urllib.parse import urlsplit

SENTINEL = "labnow-runtime"
AUDIENCE = "labnow-console-workspace-model-v1"
HEADER = {"alg": "HS256", "typ": "labnow-run+jwt", "v": 1}
TOKEN_PREFIX = base64.urlsafe_b64encode(json.dumps(HEADER, separators=(",", ":")).encode()).decode().rstrip("=") + "."
DIRECTORY = Path("/etc/labnow")
_INSTALLED = False


class WorkspaceTransportError(RuntimeError):
    def __init__(self):
        super().__init__("平台模型运行身份或固定传输入口不可用。")


def _unique(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise WorkspaceTransportError()
        value[key] = item
    return value


def _readonly_mount(fd, directory):
    info = Path("/proc/self/fdinfo/" + str(fd)).read_text()
    found = re.search(r"^mnt_id:\s*(\d+)$", info, re.M)
    if not found:
        return False
    for row in Path("/proc/self/mountinfo").read_text().splitlines():
        fields = row.split(" ")
        if fields[0] == found[1]:
            mountpoint = re.sub(r"\\([0-7]{3})", lambda m: chr(int(m[1], 8)), fields[4])
            return mountpoint == str(directory.resolve()) and "ro" in fields[5].split(",")
    return False


@dataclass(frozen=True)
class Snapshot:
    token: str = field(repr=False)
    base_url: str
    model: str
    expires_at: int
    adapter: str


class WorkspaceSource:
    def __init__(self, directory=DIRECTORY, *, adapter="hermes", verify_mount=_readonly_mount):
        # 可注入参数只供受信任装配/自动化，生产入口固定系统路径。
        self.directory = Path(directory)
        self.adapter = adapter
        self.verify_mount = verify_mount

    def _read(self, name, *, secret=False):
        path = self.directory / name
        parent = path.parent.lstat()
        if not stat.S_ISDIR(parent.st_mode) or parent.st_uid != 0 or parent.st_mode & 0o022:
            raise WorkspaceTransportError()
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as stream:
            before = os.fstat(stream.fileno())
            if (not stat.S_ISREG(before.st_mode) or before.st_uid != (os.geteuid() if secret else 0)
                    or before.st_mode & (0o077 if secret else 0o022) or before.st_size > 16384
                    or not self.verify_mount(stream.fileno(), self.directory)):
                raise WorkspaceTransportError()
            data = stream.read(16385)
            after = os.fstat(stream.fileno())
            if len(data) > 16384 or (before.st_ino, before.st_mtime_ns, before.st_ctime_ns, before.st_size) != (after.st_ino, after.st_mtime_ns, after.st_ctime_ns, after.st_size):
                raise WorkspaceTransportError()
        return data, json.loads(data, object_pairs_hook=_unique)

    def read(self):
        try:
            before, policy = self._read("openclaw-managed-identity.json")
            if (not isinstance(policy, dict) or set(policy) != {"version", "protected_env"}
                    or type(policy["version"]) is not int or policy["version"] != 1
                    or policy["protected_env"] != ["LABNOW_RUN_TOKEN"]):
                raise WorkspaceTransportError()
            credential_bytes, credentials = self._read("openclaw-runtime-identity.json", secret=True)
            if not isinstance(credentials, dict) or set(credentials) != {"LABNOW_RUN_TOKEN"}:
                raise WorkspaceTransportError()
            token = credentials["LABNOW_RUN_TOKEN"]
            if not isinstance(token, str) or len(token) > 4096 or not re.fullmatch(r"[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]{43}", token) or not token.startswith(TOKEN_PREFIX):
                raise WorkspaceTransportError()
            encoded = token.split(".")[1]
            claims = json.loads(base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)), object_pairs_hook=_unique)
            descriptor_bytes, descriptor = self._read("workspace-model.json")
            if (not isinstance(descriptor, dict) or set(descriptor) != {"version", "adapter_id", "base_url", "model", "expires_at"}
                    or type(descriptor["version"]) is not int or descriptor["version"] != 1
                    or descriptor["adapter_id"] != self.adapter or descriptor["model"] != "labnow-managed"
                    or type(descriptor["expires_at"]) is not int):
                raise WorkspaceTransportError()
            target = urlsplit(descriptor["base_url"])
            if (target.scheme != "https" or not target.hostname or target.username or target.password or target.query or target.fragment
                    or target.path.rstrip("/") != "/console/api/token/runtime/v1"):
                raise WorkspaceTransportError()
            now = int(time.time())
            if (claims.get("aud") != AUDIENCE or claims.get("adapter") != self.adapter
                    or type(claims.get("iat")) is not int or type(claims.get("exp")) is not int
                    or claims["iat"] > now or not now < claims["exp"] <= now + 300
                    or not 0 < claims["exp"] - claims["iat"] <= 300 or claims["exp"] != descriptor["expires_at"]):
                raise WorkspaceTransportError()
            # 读期间轮换时拒绝，不使用半个新描述和半个旧身份。签名/当前权限由Console核验。
            if (self._read("openclaw-managed-identity.json")[0] != before
                    or self._read("openclaw-runtime-identity.json", secret=True)[0] != credential_bytes
                    or self._read("workspace-model.json")[0] != descriptor_bytes):
                raise WorkspaceTransportError()
            return Snapshot(token, descriptor["base_url"].rstrip("/"), descriptor["model"], claims["exp"], self.adapter)
        except Exception:
            raise WorkspaceTransportError() from None


def _platform(header):
    if not isinstance(header, str):
        return False
    value = re.sub(r"^(?i:Bearer) ", "", header)
    return value == SENTINEL or value.startswith(TOKEN_PREFIX)


def prepare_request(request, source):
    header = request.headers.get("authorization")
    if not _platform(header) and not request.extensions.get("labnow_workspace_sent"):
        return
    if request.extensions.get("labnow_workspace_sent") or request.headers.get("x-stainless-retry-count", "0") != "0":
        raise WorkspaceTransportError()  # 处理原生redirect/SDK重试，不能再次发出模型操作。
    snapshot = source.read()
    target, expected = urlsplit(str(request.url)), urlsplit(snapshot.base_url)
    base = expected.path.rstrip("/")
    path = target.path.rstrip("/")
    if (target.scheme != expected.scheme or target.netloc != expected.netloc or target.username or target.password
            or target.query or target.fragment or (request.method, path) not in {
                ("POST", base + "/chat/completions"), ("GET", base + "/models")}):
        raise WorkspaceTransportError()
    for name, value in request.headers.items():
        if name.lower() != "authorization" and TOKEN_PREFIX in value:
            raise WorkspaceTransportError()
    # Next主干trailingSlash开启；直接发规范路径，不把JWT交给HTTP重定向。
    request.url = request.url.copy_with(path=path + "/")
    request.headers["authorization"] = "Bearer " + snapshot.token
    request.extensions["labnow_workspace_sent"] = True


def install(*, source=None):
    global _INSTALLED
    if _INSTALLED or os.environ.get("LABNOW_RUN_MANAGED") != "1":
        return
    import httpx
    if getattr(httpx, "_labnow_workspace_transport_installed", False):
        _INSTALLED = True
        return
    try:
        import openai
    except ImportError:
        openai = None
    source = source or WorkspaceSource()
    for cls, asynchronous in [(httpx.Client, False), (httpx.AsyncClient, True)]:
        original = cls.__init__
        def make(original, asynchronous):
            @wraps(original)
            def initialize(self, *args, **kwargs):
                original(self, *args, **kwargs)
                if asynchronous:
                    async def check(request):
                        prepare_request(request, source)
                else:
                    def check(request):
                        prepare_request(request, source)
                self.event_hooks.setdefault("request", []).append(check)
            return initialize
        cls.__init__ = make(original, asynchronous)
    for cls in ([openai.OpenAI, openai.AsyncOpenAI] if openai is not None else []):
        original = cls.__init__
        def make(original):
            @wraps(original)
            def initialize(self, *args, **kwargs):
                if kwargs.get("api_key") == SENTINEL or _platform("Bearer " + str(kwargs.get("api_key", ""))):
                    kwargs["max_retries"] = 0
                original(self, *args, **kwargs)
            return initialize
        cls.__init__ = make(original)
    httpx._labnow_workspace_transport_installed = True
    _INSTALLED = True


if __name__ == "__labnow_install__":
    install()
