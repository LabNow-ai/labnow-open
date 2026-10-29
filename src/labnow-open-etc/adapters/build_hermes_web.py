"""以已固定的 Hermes/Vite 合同构建路径前缀兼容前端，不安装新依赖。"""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import sys

EXPECTED_CONFIG = '581b18e0b28def9f4cb26773d0e52f3c6eed73a105436df384be79f1337d3d2f'


def build(root: Path):
    config = root / 'web/vite.config.ts'
    if hashlib.sha256(config.read_bytes()).hexdigest() != EXPECTED_CONFIG:
        raise RuntimeError('Hermes 前端配置版本不匹配，停止前缀适配构建。')
    vite = root / 'node_modules/vite'
    if json.loads((vite / 'package.json').read_text()).get('version') != '8.2.0':
        raise RuntimeError('Hermes Vite 版本不匹配。')
    source = Path(__file__).with_name('hermes_vite_prefix.config.mjs')
    target = root / 'web/labnow.vite.config.mjs'
    shutil.copyfile(source, target)
    subprocess.run(['node', str(vite / 'bin/vite.js'), 'build', '--config', str(target)], cwd=root / 'web', check=True)
    print('Hermes 前端已使用运行时 Lab 前缀重建；未安装依赖。')


if __name__ == '__main__':
    build(Path(sys.argv[1]))
