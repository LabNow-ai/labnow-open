"""仅在固定 Hermes 源码上安装 Open 网页适配；未知版本停止构建。"""
from pathlib import Path
import ast
import hashlib
import shutil
import sys

EXPECTED_WEB_SHA256 = "4ecf5264dc739dc7781956abb4c9f3702548f990831a1d599a191423a5dfdf57"
EXPECTED = {
    "hermes_cli/config.py": "0c69f32ed9ea9549fa169568d81f7b33d8f3819390cd09269ca650fc82aaf72d",
    "hermes_cli/web_server_profiles.py": "6a44ed1612233ee67cdf75cc56a33fb10e42403eda9d1abb42467661b203d0ce",
    "hermes_cli/managed_scope.py": "830483c7cf2267bc30ae1e09910a1b768536e7ad5418b73dd8303e5e27ac6448",
    "agent/secret_scope.py": "5f2584dc93be49ef7e4de23f9f92a4abd05aa42aab8fc2fac40f54f9f8b9c664",
    "utils.py": "cfe09d9eb4ad803bd855fb2672e7021d9e533b0358ddb1d5a4468e43ca2b61d2",
}
MARKER = "mount_spa(app)\n"
INJECTION = "\nfrom hermes_cli.labnow_web_guard import install as _labnow_install_web_guard\n_labnow_install_web_guard(app)\n"


def install(root: Path, adapter: Path):
    for relative, digest in EXPECTED.items():
        if hashlib.sha256((root / relative).read_bytes()).hexdigest() != digest:
            raise RuntimeError("Hermes 网页保护依赖源码版本不匹配。")
    target = root / "hermes_cli/web_server.py"
    dest = root / "hermes_cli/labnow_web_guard.py"
    original = target.read_bytes()
    source = original.decode()
    # 重复安装只接受本适配产生的精确版本，不把任意带标记文件视为已保护。
    restored = source.replace(MARKER + INJECTION, MARKER)
    if hashlib.sha256(restored.encode()).hexdigest() != EXPECTED_WEB_SHA256:
        raise RuntimeError("Hermes 网页源码版本不匹配，停止安装平台身份保护。")
    tree = ast.parse(restored)
    calls = [n for n in ast.walk(tree) if isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id == "mount_spa"]
    if len(calls) != 1 or restored.count(MARKER) != 1:
        raise RuntimeError("Hermes 网页路由装配结构不匹配。")
    patched = restored.replace(MARKER, MARKER + INJECTION)
    ast.parse(patched)
    adapter_bytes = adapter.read_bytes()
    ast.parse(adapter_bytes)
    if dest.exists() and dest.read_bytes() != adapter_bytes:
        raise RuntimeError("已有不同的网页保护适配，停止覆盖。")
    if not dest.exists():
        shutil.copyfile(adapter, dest)
        dest.chmod(0o444)
    target.write_text(patched)
    print("Hermes 平台身份网页保护适配已安装；托管启动仍须核实系统策略。")


if __name__ == "__main__":
    install(Path(sys.argv[1]), Path(__file__).with_name("hermes_web_guard.py"))
