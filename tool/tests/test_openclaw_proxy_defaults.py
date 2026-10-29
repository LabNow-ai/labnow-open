"""固定启动脚本的可信上游收窄；未知输入拒绝，不替代真实代理链验收。"""
from pathlib import Path
import hashlib
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src/labnow-open-etc/adapters"))
import install_workspace_runtime as m


class OpenClawProxyDefaultsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir="/run")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.target = self.root / "start.sh"
        self.original = "#!/bin/sh\n" + m.OPENCLAW_PROXY_OLD + "\nupdate_config\n"
        self.target.write_text(self.original)
        for name in ["workspace_bootstrap.py", "workspace_transport.py", "workspace_transport.mjs", "openclaw_web_guard.mjs", "openclaw_web_config.py"]:
            (self.root / name).write_text("fixture")
        self.route = self.root / "openclaw.caddy"
        self.route_original = m.OPENCLAW_CADDY_MATCH_OLD + "\n" + m.OPENCLAW_CADDY_OLD
        self.route.write_text(self.route_original)
        self.route_sha = hashlib.sha256(self.route_original.encode()).hexdigest()
        self.scripts = {**m.SCRIPTS, "openclaw": (str(self.target), hashlib.sha256(self.original.encode()).hexdigest(), "\nupdate_config\n")}

    def install(self):
        with patch.dict(m.SCRIPTS, self.scripts), patch.object(m.subprocess, "run"), patch.object(m, "OPENCLAW_CADDY_SHA256", self.route_sha):
            m.install("openclaw", directory=self.root, script_path=self.target, caddy_route=self.route)

    def test_only_loopback_defaults_and_idempotent_install(self):
        self.install()
        first = self.target.read_text()
        self.assertIn(m.OPENCLAW_PROXY_NEW, first)
        self.assertNotIn(m.OPENCLAW_PROXY_OLD, first)
        self.assertIn(m.OPENCLAW_CADDY_NEW, self.route.read_text())
        self.assertIn(m.OPENCLAW_CADDY_MATCH_NEW, self.route.read_text())
        self.assertNotIn(m.OPENCLAW_CADDY_OLD, self.route.read_text())
        self.assertEqual(first.count("openclaw_web_config.py"), 1)
        self.assertEqual(first.count("workspace_bootstrap.py openclaw"), 1)
        self.install()
        self.assertEqual(self.target.read_text(), first)

    def test_unknown_script_is_rejected_without_overwrite(self):
        self.target.write_text(self.original + "# unknown\n")
        before = self.target.read_bytes()
        with patch.dict(m.SCRIPTS, self.scripts), patch.object(m.subprocess, "run") as run:
            with self.assertRaises(RuntimeError):
                m.install("openclaw", directory=self.root, script_path=self.target, caddy_route=self.route)
            run.assert_not_called()
        self.assertEqual(self.target.read_bytes(), before)

    def test_altered_default_is_rejected_without_overwrite(self):
        changed = self.original.replace(m.OPENCLAW_PROXY_OLD, "default_proxies='[\"10.0.0.0/8\"]'")
        self.target.write_text(changed)
        with patch.dict(m.SCRIPTS, self.scripts), patch.object(m.subprocess, "run"), patch.object(m, "OPENCLAW_CADDY_SHA256", self.route_sha):
            with self.assertRaises(RuntimeError):
                m.install("openclaw", directory=self.root, script_path=self.target, caddy_route=self.route)
        self.assertEqual(self.target.read_text(), changed)
    def test_unknown_caddy_route_rejects_before_script_write(self):
        self.route.write_text(self.route_original + "unknown\n")
        with patch.dict(m.SCRIPTS, self.scripts), patch.object(m.subprocess, "run") as run:
            with self.assertRaises(RuntimeError):
                m.install("openclaw", directory=self.root, script_path=self.target, caddy_route=self.route)
            run.assert_not_called()
        self.assertEqual(self.target.read_text(), self.original)



if __name__ == "__main__":
    unittest.main()
