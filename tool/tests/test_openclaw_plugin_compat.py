"""插件未知版本/公开SDK不满足时拒绝写入，固定入口装配幂等。"""
from pathlib import Path
import hashlib
import json
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[2]/"src/labnow-open-etc/adapters"))
import install_openclaw_plugin_compat as m

class PluginCompatTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(dir="/run");self.root=Path(self.temp.name)
        self.original='// fixture\nconst sdk = '+m.OLD+';\n'
        (self.root/"package.json").write_text(json.dumps({"name":"@larksuite/openclaw-lark","version":"2026.7.16"}))
        (self.root/"index.js").write_text(self.original)
        self.sha=patch.object(m,"EXPECTED_SHA256",hashlib.sha256(self.original.encode()).hexdigest());self.sha.start()
        fixtures = {}
        for relative, (_, original, replacement) in m.MODULE_FIXES.items():
            file = self.root/relative; file.parent.mkdir(parents=True,exist_ok=True)
            content = "// fixture\n"+original+"\n";file.write_text(content)
            fixtures[relative] = (hashlib.sha256(content.encode()).hexdigest(),original,replacement)
        self.modules=patch.dict(m.MODULE_FIXES,fixtures);self.modules.start()
    def tearDown(self): self.modules.stop();self.sha.stop();self.temp.cleanup()
    def test_missing_optional_plugin_does_not_install_or_change_other_files(self):
        self.assertFalse(m.install(self.root/"missing",check_sdk=lambda _:self.fail("不应读取SDK")))
        self.assertEqual((self.root/"index.js").read_text(),self.original)
    def test_fixed_entry_repeat_install_only_replaces_one_public_import(self):
        self.assertTrue(m.install(self.root,check_sdk=lambda _:None));once=(self.root/"index.js").read_bytes()
        self.assertTrue(m.install(self.root,check_sdk=lambda _:None));self.assertEqual(once,(self.root/"index.js").read_bytes());self.assertEqual(once.decode().count(m.NEW),1)
    def test_unknown_version_or_source_is_not_overwritten(self):
        (self.root/"package.json").write_text(json.dumps({"name":"@larksuite/openclaw-lark","version":"future"}))
        with self.assertRaises(RuntimeError):m.install(self.root,check_sdk=lambda _:self.fail("不应继续读取SDK"))
        self.assertEqual((self.root/"index.js").read_text(),self.original)
    def test_unknown_sibling_module_prevents_all_mutation(self):
        file=self.root/"src/core/version.js";file.write_text(file.read_text()+"// foreign\n")
        with self.assertRaises(RuntimeError):m.install(self.root,check_sdk=lambda _:self.fail("不应继续读取SDK"))
        self.assertEqual((self.root/"index.js").read_text(),self.original)
    def test_unavailable_public_sdk_rejects_before_mutation(self):
        def fail(_):raise RuntimeError("fixture unsupported public SDK")
        with self.assertRaises(RuntimeError):m.install(self.root,check_sdk=fail)
        self.assertEqual((self.root/"index.js").read_text(),self.original)

if __name__=="__main__":unittest.main()
