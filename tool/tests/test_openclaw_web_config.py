"""路径配置不改变身份、Provider或普通模式；原生HTTP/浏览器验收另列。"""
from pathlib import Path
import contextlib
import io
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src/labnow-open-etc/adapters"))
import openclaw_web_config as m


class OpenClawWebConfigTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir="/run")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.path = self.root / "config.json"
        self.value = {"models": {"providers": {"own": {"apiKey": "fixture-own-secret"}}}, "gateway": {"auth": {"mode": "trusted-proxy"}, "controlUi": {"existing": True}}}
        self.path.write_text(json.dumps(self.value))
        self.path.chmod(0o600)

    def test_root_and_nested_native_mounts(self):
        for prefix, expected in [("/", "/openclaw"), ("/studio/user/fixture/lab/", "/studio/user/fixture/lab/openclaw"), ("/studio/user/fixture/lab", "/studio/user/fixture/lab/openclaw")]:
            m.configure(self.path, prefix)
            value = json.loads(self.path.read_text())
            self.assertEqual(value["gateway"]["controlUi"]["basePath"], expected)
            self.assertEqual(value["models"], self.value["models"])
            self.assertEqual(value["gateway"]["auth"], self.value["gateway"]["auth"])
            self.assertTrue(value["gateway"]["controlUi"]["existing"])

    def test_ordinary_mode_needs_no_runtime_identity_and_prints_no_secrets(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            m.configure(self.path, "/ordinary/")
        self.assertEqual(output.getvalue(), "")
        self.assertEqual(json.loads(self.path.read_text())["models"], self.value["models"])

    def test_idempotent_and_private_mode_preserved(self):
        m.configure(self.path, "/lab/")
        before = self.path.read_bytes(), self.path.stat().st_mtime_ns
        m.configure(self.path, "/lab/")
        self.assertEqual((self.path.read_bytes(), self.path.stat().st_mtime_ns), before)
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)

    def test_invalid_prefixes_do_not_change_configuration(self):
        before = self.path.read_bytes()
        for prefix in ["https://foreign/", "//foreign/", "/../", "/%2f/", "/%252f/", "/a\\b/", "/a?x", "/a#x", "/a\r/"]:
            with self.subTest(prefix=prefix), self.assertRaises(RuntimeError):
                m.configure(self.path, prefix)
            self.assertEqual(self.path.read_bytes(), before)

    def test_invalid_configuration_error_has_no_content(self):
        self.path.write_text('{"gateway":"fixture-own-secret"}')
        before = self.path.read_bytes()
        with self.assertRaises(RuntimeError) as caught:
            m.configure(self.path, "/lab/")
        self.assertNotIn("fixture-own-secret", str(caught.exception))
        self.assertEqual(self.path.read_bytes(), before)

    def test_symlink_rejects_without_changing_target(self):
        link = self.root / "link.json"
        link.symlink_to(self.path)
        before = self.path.read_bytes()
        with self.assertRaises(RuntimeError):
            m.configure(link, "/lab/")
        self.assertEqual(self.path.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
