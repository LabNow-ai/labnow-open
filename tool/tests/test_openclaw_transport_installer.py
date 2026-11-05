"""原生模型出口装配：未知版本拒绝及两处CLI的原子前置核对。"""
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ADAPTERS=Path(__file__).resolve().parents[2]/"src/labnow-open-etc/adapters"
sys.path.insert(0,str(ADAPTERS))
import install_openclaw_transport as m

class InstallerTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory(dir="/run");self.root=Path(self.temp.name)
  self.values={name:("// fixture\n"+m.ORIGINAL+"\n" if name.startswith("provider-") else "// fixture dependency "+name+"\n") for name in m.EXPECTED}
  self.expected=patch.dict(m.EXPECTED,{name:hashlib.sha256(value.encode()).hexdigest() for name,value in self.values.items()});self.expected.start()
  self.roots=[self.root/"global",self.root/"project"]
  for root in self.roots:
   (root/"dist").mkdir(parents=True)
   for name,value in self.values.items():(root/"dist"/name).write_text(value)
 def tearDown(self):self.expected.stop();self.temp.cleanup()
 def targets(self):return [root/"dist/provider-transport-fetch-B_VndpTk.mjs" for root in self.roots]
 def test_repeat_install_covers_both_cli_sources(self):
  m.install(self.roots);first=[p.read_bytes() for p in self.targets()];m.install(self.roots)
  self.assertEqual(first,[p.read_bytes() for p in self.targets()])
  for p in self.targets():self.assertEqual(p.read_text().count(m.IMPORT),1);self.assertEqual(p.read_text().count(m.PATCHED),1)
 def test_second_cli_unknown_source_does_not_change_first(self):
  before=self.targets()[0].read_bytes();self.targets()[1].write_text("// foreign source\n")
  with self.assertRaises(RuntimeError):m.install(self.roots)
  self.assertEqual(before,self.targets()[0].read_bytes());self.assertEqual(self.targets()[1].read_text(),"// foreign source\n")
 def test_native_guard_or_dispatcher_dependency_change_rejects_before_patch(self):
  before=[p.read_bytes() for p in self.targets()]
  for name in ["fetch-guard-BulPh3pN.mjs","runtime-fetch-DkWhaX5J.mjs"]:
   path=self.roots[0]/"dist"/name;path.write_text("// foreign dependency\n")
   with self.assertRaises(RuntimeError):m.install(self.roots)
   self.assertEqual(before,[p.read_bytes() for p in self.targets()]);path.write_text(self.values[name])

if __name__=="__main__":unittest.main()
