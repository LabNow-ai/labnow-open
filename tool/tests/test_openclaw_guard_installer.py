"""安装结构与未知版本拒绝单测；固定镜像源码另行校验。"""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ADAPTER = Path(__file__).resolve().parents[2] / "src/labnow-open-etc/adapters"
spec = importlib.util.spec_from_file_location("openclaw_guard_installer", ADAPTER / "install_openclaw_guard.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallerTests(unittest.TestCase):
    def test_install_repeat_and_unknown_source_preserved(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); dist = root / "dist"; dist.mkdir()
            target = dist / "secrets-CDMMk0N2.mjs"
            raw = installer.START + "\n" + installer.END
            target.write_text(raw)
            expected = {target.name: hashlib.sha256(raw.encode()).hexdigest()}
            with patch.object(installer, "EXPECTED", expected):
                installer.install(root, ADAPTER / "openclaw_web_guard.mjs")
                first = target.read_bytes(); installer.install(root, ADAPTER / "openclaw_web_guard.mjs")
                self.assertEqual(first, target.read_bytes())
                self.assertIn(installer.PATCHED_START, first.decode())
                self.assertEqual((dist / "labnow_openclaw_guard.mjs").read_bytes(), (ADAPTER / "openclaw_web_guard.mjs").read_bytes())
                target.write_bytes(first + b"// unknown change\n")
                with self.assertRaises(RuntimeError): installer.install(root, ADAPTER / "openclaw_web_guard.mjs")
                self.assertEqual(target.read_bytes(), first + b"// unknown change\n")

    def test_foreign_adapter_not_overwritten(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); dist = root / "dist"; dist.mkdir()
            raw = installer.START + "\n" + installer.END
            (dist / "secrets-CDMMk0N2.mjs").write_text(raw)
            existing = dist / "labnow_openclaw_guard.mjs"; existing.write_text("foreign")
            with patch.object(installer, "EXPECTED", {"secrets-CDMMk0N2.mjs": hashlib.sha256(raw.encode()).hexdigest()}):
                with self.assertRaises(RuntimeError): installer.install(root, ADAPTER / "openclaw_web_guard.mjs")
                self.assertEqual(existing.read_text(), "foreign")

    def test_fixed_entry_marker_and_package_version_both_required(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); entry = root / "openclaw"; package = root / "pkg"; package.mkdir()
            (package / "openclaw.mjs").write_text("// fixture")
            (package / "package.json").write_text(json.dumps({"version": "2026.9.8"}))
            raw = b"#!/bin/sh\n# cmd-shim-target=pkg/openclaw.mjs\n"; entry.write_bytes(raw)
            with patch.object(installer, "ENTRY_TARGETS", {hashlib.sha256(raw).hexdigest(): "pkg/openclaw.mjs"}):
                self.assertEqual(installer.package_for_entry(entry), package)
                (package / "package.json").write_text('{"version":"unknown"}')
                with self.assertRaises(RuntimeError): installer.package_for_entry(entry)
                entry.write_bytes(raw + b"# changed\n")
                with self.assertRaises(RuntimeError): installer.package_for_entry(entry)


if __name__ == "__main__": unittest.main()
