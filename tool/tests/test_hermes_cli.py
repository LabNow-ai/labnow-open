"""固定原生Hermes的真实CLI导入；不启动Agent或外部模型。"""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

@unittest.skipUnless(all(importlib.util.find_spec(name) for name in ["run_agent", "openai", "prompt_toolkit"]), "需完整固定Hermes原生CLI依赖")
class NativeHermesCLITests(unittest.TestCase):
    def test_actual_cli_imports_with_writable_private_home_and_no_model_request(self):
        with tempfile.TemporaryDirectory(dir="/run") as home:
            environment = dict(os.environ, HOME=home, HERMES_HOME=home+"/hermes", PYTHONDONTWRITEBYTECODE="1")
            environment.pop("LABNOW_RUN_MANAGED", None)
            probe = "import cli,prompt_toolkit; assert prompt_toolkit.__version__ == '3.0.52'; assert hasattr(cli, 'main')"
            result = subprocess.run([sys.executable, "-c", probe], env=environment, text=True, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr[-4000:])

if __name__ == "__main__": unittest.main()
