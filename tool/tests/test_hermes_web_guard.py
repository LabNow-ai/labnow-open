"""纯策略测试；原生 FastAPI/Hermes 组合需在固定运行依赖中执行，不以 skip 代替。"""
from contextlib import nullcontext
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "src/labnow-open-etc/adapters/hermes_web_guard.py"
spec = importlib.util.spec_from_file_location("open_hermes_guard", ADAPTER)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)
native = importlib.util.find_spec("hermes_cli") is not None and importlib.util.find_spec("fastapi") is not None
KEY = "LABNOW_RUN_API_KEY"
VALUE = "fixture-managed-identity-value-A"
OWN = "fixture-self-owned-value"


class PolicyFixture:
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="open-web-guard-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.admin = self.root / "admin"
        self.config = self.root / "policy"
        self.home = self.root / "home"
        for path in (self.admin, self.config, self.home):
            path.mkdir(mode=0o700)
        self.policy = self.config / "managed-identity.json"
        self.policy.write_text(json.dumps({"version": 1, "protected_env": [KEY]}))
        self.env = self.admin / ".env"
        self.env.write_text(KEY + "=" + VALUE + "\n")
        self.policy.chmod(0o444)
        self.env.chmod(0o444)
        self.settings = patch.dict(os.environ, {"HERMES_MANAGED_DIR": str(self.admin), "HERMES_HOME": str(self.home)})
        self.settings.start()
        self.addCleanup(self.settings.stop)
        if not native:
            modules = {
                "hermes_cli.managed_scope": types.SimpleNamespace(get_managed_dir=lambda: Path(os.environ["HERMES_MANAGED_DIR"])),
                "agent.secret_scope": types.SimpleNamespace(_parse_env_text=lambda text: dict(line.split("=", 1) for line in text.splitlines() if line)),
            }
            stub = patch.dict(sys.modules, modules)
            stub.start()
            self.addCleanup(stub.stop)
        self.source = guard.PolicySource(self.policy, self.admin)

    def rewrite_policy(self, value):
        self.policy.chmod(0o644)
        self.policy.write_text(value if isinstance(value, str) else json.dumps(value))
        self.policy.chmod(0o444)


class PolicyTests(PolicyFixture, unittest.TestCase):
    def test_root_controlled_policy_and_native_source_snapshot(self):
        names, values, digest = self.source.snapshot(required=True)
        self.assertEqual(names, (KEY,))
        self.assertEqual(values, (VALUE,))
        self.assertEqual(len(digest), 32)

    def test_absent_policy_is_ordinary_but_required_is_sticky(self):
        self.policy.unlink()
        self.env.chmod(0o644)
        self.env.write_text("SELF_OWNED_API_KEY="+OWN+"\n")
        self.env.chmod(0o444)
        self.assertIsNone(self.source.snapshot())
        with self.assertRaises(guard.GuardFailure):
            self.source.snapshot(required=True)
        with self.assertRaises(guard.GuardFailure):
            self.source.snapshot()

    def test_absent_policy_with_platform_root_secret_rejects_startup(self):
        self.policy.unlink()
        with self.assertRaises(guard.GuardFailure):
            self.source.snapshot()
        self.env.unlink()
        with self.assertRaises(guard.GuardFailure):
            self.source.snapshot()

    def test_enabled_policy_and_secret_source_disappearance_fail_closed(self):
        self.source.snapshot()
        self.env.unlink()
        with self.assertRaises(guard.GuardFailure):
            self.source.snapshot()
        self.policy.unlink()
        with self.assertRaises(guard.GuardFailure):
            self.source.snapshot()

    def test_invalid_policy_cannot_then_disappear_into_disabled_mode(self):
        self.rewrite_policy("invalid-json")
        with self.assertRaises(guard.GuardFailure):
            self.source.snapshot()
        self.policy.unlink()
        with self.assertRaises(guard.GuardFailure):
            self.source.snapshot()

    def test_wrong_schema_duplicate_provider_key_and_unknown_fields(self):
        for data in [
            {"version": True, "protected_env": [KEY]},
            {"version": 1, "protected_env": []},
            {"version": 1, "protected_env": [KEY, KEY]},
            {"version": 1, "protected_env": ["OPENAI_API_KEY"]},
            {"version": 1, "protected_env": ["LABNOW_RUN_K"+str(i) for i in range(9)]},
            {"version": 1, "protected_env": [KEY], "enabled": False},
        ]:
            with self.subTest(data=data):
                self.rewrite_policy(data)
                with self.assertRaises(guard.GuardFailure):
                    self.source.snapshot()

    def test_names_change_requires_restart(self):
        self.source.snapshot()
        self.rewrite_policy({"version": 1, "protected_env": ["LABNOW_RUN_OTHER_IDENTITY"]})
        with self.assertRaises(guard.GuardFailure):
            self.source.snapshot()

    def test_secret_rotation_changes_snapshot(self):
        before = self.source.snapshot()
        other = self.env.with_suffix(".next")
        other.write_text(KEY+"=fixture-managed-identity-value-B\n")
        other.chmod(0o444)
        other.replace(self.env)
        after = self.source.snapshot()
        self.assertNotEqual(before[2], after[2])

    def test_user_env_cannot_choose_source_directory(self):
        os.environ["HERMES_MANAGED_DIR"] = str(self.home)
        with self.assertRaises(guard.GuardFailure):
            self.source.snapshot()

    def test_symlink_policy_or_parent_rejected(self):
        other = self.root / "other.json"
        other.write_bytes(self.policy.read_bytes())
        self.policy.unlink()
        self.policy.symlink_to(other)
        with self.assertRaises(guard.GuardFailure):
            self.source.snapshot()
        alias = self.root / "alias"
        alias.symlink_to(self.config, target_is_directory=True)
        with self.assertRaises(guard.GuardFailure):
            guard.PolicySource(alias / self.policy.name, self.admin).snapshot()

    def test_group_or_world_writable_policy_parent_and_secret_rejected(self):
        for path in (self.policy, self.config, self.env, self.admin):
            original = path.stat().st_mode & 0o777
            path.chmod(original | 0o020)
            with self.subTest(path=path.name), self.assertRaises(guard.GuardFailure):
                self.source.snapshot()
            path.chmod(original)

    def test_non_root_policy_is_rejected(self):
        if os.getuid() != 0:
            self.skipTest("需要root测试所有权拒绝，运行镜像内执行")
        os.chown(self.policy, 12345, -1)
        with self.assertRaises(guard.GuardFailure):
            self.source.snapshot()
        os.chown(self.policy, 0, -1)

    def test_empty_missing_or_reference_secret_rejected(self):
        for value in ["", "short", "${OTHER_KEY}", ""]:
            self.env.chmod(0o644)
            self.env.write_text(KEY+"="+value+"\n")
            self.env.chmod(0o444)
            with self.assertRaises(guard.GuardFailure):
                self.source.snapshot()

    def test_body_reference_and_key_env_pointer(self):
        for value in ["${"+KEY+"}", "${env:"+KEY+"}", "prefix ${ env: "+KEY+" } suffix", {"nested": ["${"+KEY+"}"]}]:
            with self.assertRaises(guard.GuardFailure):
                guard.check_references(value, [KEY])
        for value in [{"key_env": KEY}, "${SELF_OWNED_API_KEY}", "${vault:SECRET}", "normal"]:
            guard.check_references(value, [KEY])

    def test_known_values_are_detected_after_json_decode(self):
        self.assertTrue(guard._contains_value({"nested": [VALUE]}, [VALUE]))
        self.assertFalse(guard._contains_value({"key_env": KEY, "own": OWN}, [VALUE]))


@unittest.skipUnless(native, "固定Hermes/FastAPI运行依赖未安装，须用运行镜像验收")
class NativeRouteTests(PolicyFixture, unittest.TestCase):
    def setUp(self):
        super().setUp()
        from fastapi import FastAPI, HTTPException
        from fastapi.responses import JSONResponse, StreamingResponse
        from fastapi.testclient import TestClient
        self.app = FastAPI()
        self.mutations = []
        @self.app.middleware("http")
        async def fixture_auth(request, call_next):
            # 这是鉴权顺序夹具，真实Hermes鉴权另行R，不替换原生部署鉴权。
            if request.headers.get("x-fixture-auth") != "yes":
                return JSONResponse({"detail": "fixture unauthorized"}, status_code=401)
            return await call_next(request)
        @self.app.get("/api/config")
        async def config():
            return self.result
        @self.app.put("/api/config")
        async def update_config():
            self.mutations.append(True)
            return {"ok": True}
        @self.app.post("/api/env/reveal")
        async def reveal():
            return {"value": OWN}
        @self.app.put("/api/env")
        async def update_env():
            self.mutations.append(True)
            return {"ok": True}
        @self.app.get("/api/env")
        async def env():
            return {KEY: {"redacted_value": "fixture"}, "SELF_OWNED_API_KEY": {"redacted_value": "own"}}
        @self.app.get("/fixture/error")
        async def error():
            raise HTTPException(400, detail=self.result)
        @self.app.get("/fixture/rotate")
        async def rotate():
            self.env.chmod(0o644)
            self.env.write_text(KEY+"=fixture-managed-identity-value-B\n")
            self.env.chmod(0o444)
            return {"value": VALUE}
        @self.app.get("/api/config/stream")
        async def streaming():
            return StreamingResponse(iter([b"fixture"]))
        self.result = {"key_env": KEY, "display": {"text": "normal"}}
        self.raw = {"display": {"text": "normal"}}
        # 原生profile/文件读取入口单独替身；测试实际FastAPI route包装与响应，不冒充原生配置R。
        self.profile = patch("hermes_cli.web_server_profiles._config_profile_scope", lambda profile: nullcontext())
        self.profile.start()
        self.addCleanup(self.profile.stop)
        self.file = self.home / "config.yaml"
        self.file.write_text("{}")
        for name, value in [("get_config_path", lambda: self.file), ("read_user_config_raw", lambda: self.raw)]:
            p = patch("hermes_cli.config."+name, value)
            p.start()
            self.addCleanup(p.stop)
        guard.install(self.app, self.source)
        self.client = TestClient(self.app)
        self.addCleanup(self.client.close)
        self.headers = {"x-fixture-auth": "yes"}

    def test_native_route_auth_runs_before_guard(self):
        self.raw = {"display": "${"+KEY+"}"}
        self.assertEqual(self.client.get("/api/config").status_code, 401)
        self.assertEqual(self.client.get("/api/config", headers=self.headers).status_code, 403)

    def test_native_route_normal_config_and_own_key_remain_available(self):
        response = self.client.get("/api/config", headers=self.headers)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), self.result)
        self.assertEqual(response.headers["cache-control"], "no-store")
        self.assertEqual(self.client.post("/api/env/reveal", json={"key": "SELF_OWNED_API_KEY"}, headers=self.headers).json()["value"], OWN)

    def test_native_route_rejects_refs_and_direct_value_before_mutation(self):
        for value in ["${"+KEY+"}", {"nested": ["${env:"+KEY+"}"]}, VALUE]:
            response = self.client.put("/api/config", json={"config": {"display": value}}, headers=self.headers)
            self.assertEqual(response.status_code, 403)
        self.assertEqual(self.mutations, [])

    def test_native_route_encoded_path_keeps_protection(self):
        response = self.client.put("/api/%63onfig", json={"config": {"display": "${"+KEY+"}"}}, headers=self.headers)
        self.assertEqual(response.status_code, 403)
        self.assertEqual(self.mutations, [])

    def test_native_route_protected_env_is_not_revealed_written_or_listed(self):
        for method, path in [("POST", "/api/env/reveal"), ("PUT", "/api/env")]:
            self.assertEqual(self.client.request(method, path, json={"key": KEY, "value": "fixture-new-value"}, headers=self.headers).status_code, 403)
        self.assertNotIn(KEY, self.client.get("/api/env", headers=self.headers).json())
        self.assertEqual(self.mutations, [])

    def test_native_route_raw_existing_reference_blocks_before_render(self):
        self.raw = {"display": ["${"+KEY+"}"]}
        self.assertEqual(self.client.get("/api/config", headers=self.headers).status_code, 403)

    def test_native_route_cached_or_escaped_value_does_not_return(self):
        self.result = {"nested": [VALUE]}
        result = self.client.get("/api/config", headers=self.headers)
        self.assertEqual(result.status_code, 403)
        self.assertNotIn(VALUE, result.text)

    def test_native_route_error_detail_is_filtered(self):
        self.result = {"private": VALUE}
        response = self.client.get("/fixture/error", headers=self.headers)
        self.assertEqual(response.status_code, 403)
        self.assertNotIn(VALUE, response.text)

    def test_native_route_rotation_source_failure_and_stream_fail_closed(self):
        self.assertEqual(self.client.get("/fixture/rotate", headers=self.headers).status_code, 503)
        self.assertEqual(self.client.get("/api/config/stream", headers=self.headers).status_code, 503)
        self.env.unlink()
        self.assertEqual(self.client.get("/api/config", headers=self.headers).status_code, 503)

    def test_native_route_repeat_install_is_idempotent(self):
        original = self.app.routes[-1].app
        guard.install(self.app, self.source)
        self.assertIs(self.app.routes[-1].app, original)

    def test_native_route_ordinary_mode_preserves_original_response(self):
        from fastapi import FastAPI
        from fastapi.responses import JSONResponse
        from fastapi.testclient import TestClient
        self.policy.unlink()
        self.env.chmod(0o644)
        self.env.write_text("SELF_OWNED_API_KEY="+OWN+"\n")
        self.env.chmod(0o444)
        app = FastAPI()
        response = JSONResponse({"value": OWN}, status_code=201, headers={"x-fixture-original": "yes"})
        @app.get("/api/config")
        async def original():
            return response
        guard.install(app, guard.PolicySource(self.policy, self.admin))
        with TestClient(app) as client:
            result = client.get("/api/config")
        self.assertEqual(result.status_code, 201)
        self.assertEqual(result.content, response.body)
        self.assertEqual(result.headers["x-fixture-original"], "yes")
        self.assertNotIn("cache-control", result.headers)


class InstallerTests(unittest.TestCase):
    def test_source_contract_install_repeat_and_mismatch(self):
        installer_path = ADAPTER.with_name("install_hermes_guard.py")
        spec = importlib.util.spec_from_file_location("open_guard_installer", installer_path)
        installer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(installer)
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "hermes_cli").mkdir()
            target = root / "hermes_cli/web_server.py"
            raw = b"mount_spa(app)\n"
            target.write_bytes(raw)
            dependency = root / "dependency.py"
            dependency.write_text("# fixture\n")
            with patch.object(installer, "EXPECTED_WEB_SHA256", hashlib.sha256(raw).hexdigest()), patch.object(installer, "EXPECTED", {"dependency.py": hashlib.sha256(dependency.read_bytes()).hexdigest()}):
                installer.install(root, ADAPTER)
                first = target.read_bytes()
                installer.install(root, ADAPTER)
                self.assertEqual(first, target.read_bytes())
                target.write_bytes(first+b"# unknown upgrade\n")
                with self.assertRaises(RuntimeError):
                    installer.install(root, ADAPTER)
                self.assertEqual(target.read_bytes(), first+b"# unknown upgrade\n")


@unittest.skipUnless(native, "固定Hermes源码需在运行镜像核实")
class NativeSourceInstallTests(unittest.TestCase):
    def test_fixed_real_source_manifest_and_install(self):
        installer_path = ADAPTER.with_name("install_hermes_guard.py")
        spec = importlib.util.spec_from_file_location("native_guard_installer", installer_path)
        installer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(installer)
        import hermes_cli
        real = Path(hermes_cli.__file__).resolve().parents[1]
        paths = ["hermes_cli/web_server.py", *installer.EXPECTED]
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for relative in paths:
                target = root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes((real / relative).read_bytes())
            installer.install(root, ADAPTER)
            for relative, digest in installer.EXPECTED.items():
                self.assertEqual(hashlib.sha256((root / relative).read_bytes()).hexdigest(), digest)
            web = (root / "hermes_cli/web_server.py").read_text()
            self.assertIn(installer.INJECTION, web)
            self.assertEqual((root / "hermes_cli/labnow_web_guard.py").read_bytes(), ADAPTER.read_bytes())


if __name__ == "__main__":
    unittest.main()
