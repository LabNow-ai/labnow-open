"""消费者装配与原有配置兼容回归；无模型请求。"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ADAPTERS = Path(__file__).resolve().parents[2] / "src/labnow-open-etc/adapters"
sys.path.insert(0, str(ADAPTERS))
import workspace_bootstrap as b
import install_workspace_runtime as i

BASE = "https://console.invalid/console/api/token/runtime/v1"
class Description:
    def __init__(self, adapter): self.adapter = adapter
    def _read(self, name):
        value = ({"version": 1, "protected_env": ["LABNOW_RUN_TOKEN"]} if name == "openclaw-managed-identity.json" else
                 {"version": 1, "adapter_id": self.adapter, "base_url": BASE, "model": "labnow-managed", "expires_at": 1})
        return json.dumps(value).encode(), value

class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir="/run")
        self.root = Path(self.temp.name)
        self.file = self.root / "config.json"
        self.previous = {"gateway": {"mode": "local", "auth": {"mode": "token", "token": "fixture-ordinary-gateway"}},
                         "plugins": {"allow": ["example"]}, "models": {"mode": "merge", "providers": {"own": {"apiKey": "fixture-own-key"}}},
                         "agents": {"defaults": {"model": {"primary": "own/example", "fallbacks": ["own/fallback"]}}}}
        self.file.write_text(json.dumps(self.previous))
        self.environment = patch.dict(os.environ, {"LABNOW_RUN_MANAGED": "1"});self.environment.start()
    def tearDown(self): self.environment.stop();self.temp.cleanup()
    def test_openclaw_preserves_gateway_plugins_own_provider_and_fallbacks(self):
        self.assertTrue(b.bootstrap("openclaw", source=Description("openclaw"), config_path=self.file))
        result = json.loads(self.file.read_text())
        for field in ["gateway", "plugins"]: self.assertEqual(result[field], self.previous[field])
        self.assertEqual(result["models"]["providers"]["own"], self.previous["models"]["providers"]["own"])
        self.assertEqual(result["agents"]["defaults"]["model"]["fallbacks"], ["own/fallback"])
        self.assertEqual(result["agents"]["defaults"]["model"]["primary"], "labnow-managed/labnow-managed")
        self.assertEqual(result["models"]["providers"]["labnow-managed"]["apiKey"], "labnow-runtime")
        self.assertNotIn("LABNOW_RUN_TOKEN", self.file.read_text())
        self.assertEqual(self.file.stat().st_mode & 0o777, 0o600)
        first = self.file.read_bytes(); b.bootstrap("openclaw", source=Description("openclaw"), config_path=self.file)
        self.assertEqual(first, self.file.read_bytes())
    def test_reserved_provider_collision_keeps_original_user_file(self):
        self.previous["models"]["providers"]["labnow-managed"] = {"apiKey": "fixture-own-key"}
        self.file.write_text(json.dumps(self.previous)); original = self.file.read_bytes()
        with self.assertRaises(b.WorkspaceTransportError): b.bootstrap("openclaw", source=Description("openclaw"), config_path=self.file)
        self.assertEqual(original, self.file.read_bytes())
    def test_unknown_shape_or_symlink_does_not_mutate_original(self):
        for bad in [{"models": []}, {"agents": []}, []]:
            self.file.write_text(json.dumps(bad)); original = self.file.read_bytes()
            with self.assertRaises(b.WorkspaceTransportError): b.bootstrap("openclaw", source=Description("openclaw"), config_path=self.file)
            self.assertEqual(original, self.file.read_bytes())
        link = self.root / "link";link.symlink_to(self.file)
        with self.assertRaises(b.WorkspaceTransportError): b.bootstrap("openclaw", source=Description("openclaw"), config_path=link)
    def test_ordinary_mode_does_not_read_or_write(self):
        with patch.dict(os.environ, {"LABNOW_RUN_MANAGED": "0"}):
            self.assertFalse(b.bootstrap("openclaw", config_path=self.root / "absent"))
    def test_hermes_requires_launcher_contract_and_never_writes_it(self):
        value = {"model": {"provider": "custom", "default": "labnow-managed", "base_url": BASE,
                           "api_mode": "chat_completions", "api_key": "labnow-runtime"}}
        self.file.write_text(json.dumps(value)); original = self.file.read_bytes()
        self.assertTrue(b.bootstrap("hermes", source=Description("hermes"), config_path=self.file))
        self.assertEqual(original, self.file.read_bytes())
        value["model"]["api_key"] = "fixture-own-key";self.file.write_text(json.dumps(value))
        with self.assertRaises(b.WorkspaceTransportError): b.bootstrap("hermes", source=Description("hermes"), config_path=self.file)
    def test_descriptor_cannot_change_adapter_or_destination(self):
        with self.assertRaises(b.WorkspaceTransportError): b.bootstrap("openclaw", source=Description("hermes"), config_path=self.file)

class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir="/run");self.root=Path(self.temp.name)
        self.script = self.root / "start.sh";self.original = "#!/bin/sh\nset -eu\necho fixture\n";self.script.write_text(self.original)
        self.scripts = patch.dict(i.SCRIPTS, {"hermes": (str(self.script), hashlib.sha256(self.original.encode()).hexdigest(), "set -eu\n")});self.scripts.start()
    def tearDown(self): self.scripts.stop();self.temp.cleanup()
    def test_repeat_install_is_identical_and_ordinary_path_stays_guarded(self):
        i.install("hermes", directory=ADAPTERS, script_path=self.script, purelibs=[self.root])
        first=self.script.read_bytes();i.install("hermes", directory=ADAPTERS, script_path=self.script, purelibs=[self.root])
        self.assertEqual(first,self.script.read_bytes());self.assertEqual(self.script.read_text().count("workspace_bootstrap.py"),1)
        self.assertIn('"${LABNOW_RUN_MANAGED:-}" = "1"',self.script.read_text())
        self.assertIn('"${1:-}" != "healthcheck"',self.script.read_text())
        self.assertEqual((self.root / "labnow_workspace_identity.pth").stat().st_mode & 0o777,0o444)
    def test_unknown_upstream_is_preserved(self):
        self.script.write_text(self.original+"# unknown\n");original=self.script.read_bytes()
        with self.assertRaises(RuntimeError):i.install("hermes",directory=ADAPTERS,script_path=self.script,purelibs=[self.root])
        self.assertEqual(original,self.script.read_bytes());self.assertFalse((self.root / "labnow_workspace_identity.pth").exists())
    def test_foreign_python_hook_is_preserved(self):
        hook=self.root / "labnow_workspace_identity.pth";hook.write_text("# another integration\n")
        with self.assertRaises(RuntimeError):i.install("hermes",directory=ADAPTERS,script_path=self.script,purelibs=[self.root])
        self.assertEqual(hook.read_text(),"# another integration\n");self.assertEqual(self.script.read_text(),self.original)
    def test_unknown_adapter_refused(self):
        with self.assertRaises(RuntimeError):i.install("foreign",directory=ADAPTERS,script_path=self.script,purelibs=[self.root])

if __name__ == "__main__":unittest.main()
