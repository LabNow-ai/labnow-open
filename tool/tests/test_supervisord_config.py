"""只执行 Dockerfile 的配置生成片段；不构建镜像或启动应用。"""

import configparser
import itertools
import json
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
DOCKERFILE = ROOT / "src/labnow-open.Dockerfile"
CONFIG = ROOT / "src/labnow-open-etc/supervisord.conf"
SERVICES = ("jupyter", "code-server", "rserver", "shiny-server", "openclaw")
ROUTES = ("jupyter", "vscode", "rserver", "shiny", "openclaw", "hermes", "selkies")
INHERITED = """
[program:hermes]
command=/opt/hermes/start-hermes.sh
autostart=true
autorestart=true

[program:selkies]
command=/opt/selkies/start.sh
autostart=false
"""


def parse_config(text):
    parser = configparser.RawConfigParser()
    parser.read_string(text)
    return {section: dict(parser.items(section)) for section in parser.sections()}


def generate_config(available, inherited=False):
    """探测命令用替身，三个输出路径全部重定向到临时目录。"""
    source = DOCKERFILE.read_text()
    fragment = source.split("## handle supervisord start options\n", 1)[1]
    fragment = fragment.split("## cleanup of any temporary or cache files", 1)[0]
    fragment = fragment.replace("\\\n", "").strip()
    if not fragment.startswith("&&"):
        raise AssertionError("未找到配置生成片段的起始命令")
    fragment = fragment[2:].strip()
    initial = CONFIG.read_text() + (INHERITED if inherited else "")
    with tempfile.TemporaryDirectory(prefix="labnow-open-config-") as directory:
        root = Path(directory)
        config = root / "supervisord.conf"
        routes = root / "routes"
        routes.mkdir()
        config.write_text(initial)
        for name in ROUTES:
            (routes / (name + ".caddy")).write_text("# 路由保留哨兵\n")
        jupyter = root / "jupyter.json"
        for original, replacement in (
            ("/etc/supervisord/supervisord.conf", config),
            ("/opt/labnow-open/etc/CaddyRoutes", routes),
            ("/opt/conda/etc/jupyter/jupyter_server_config.json", jupyter),
        ):
            fragment = fragment.replace(original, shlex.quote(str(replacement)))
        # 只模拟 type 的可用性，不执行任何同名应用或启动脚本。
        choices = "|".join(shlex.quote(name) for name in available)
        probe = "type() { return 1; }\n"
        if choices:
            probe = 'type() { case "$1" in ' + choices + ") return 0;; *) return 1;; esac; }\n"
        script = "set -e\n" + probe + fragment + "\n"
        subprocess.run(["bash", "-n"], input=script, text=True, check=True, capture_output=True)
        result = subprocess.run(
            ["bash", "--noprofile", "--norc"],
            input=script, text=True, check=True, capture_output=True, cwd=root,
        )
        return initial, config.read_text(), {p.stem for p in routes.iterdir()}, jupyter.read_text() if jupyter.exists() else None, result.stdout


class SupervisorConfigTests(unittest.TestCase):
    def check_hermes_selkies(self, hermes, selkies, inherited):
        available = [name for name, present in (("hermes", hermes), ("selkies", selkies)) if present]
        before, after, routes, jupyter, output = generate_config(available, inherited)
        # 解析与逐字节保持同时检查，防止提示被解析成别的配置字段。
        self.assertEqual(parse_config(after), parse_config(before))
        self.assertEqual(after, before)
        self.assertEqual(routes, set(available))
        self.assertIsNone(jupyter)
        if available:
            self.assertTrue(output.strip(), "构建提示应输出到日志")

    def test_other_programs_and_jupyter_settings_are_preserved(self):
        before, after, routes, jupyter, _ = generate_config(SERVICES, inherited=True)
        config = parse_config(after)
        for section, settings in parse_config(before).items():
            self.assertEqual(config[section], settings)
        for name, command in (
            ("jupyter", "start-jupyterlab.sh"),
            ("vscode", "start-code-server.sh"),
            ("rserver", "start-rserver.sh"),
            ("rshiny", "start-shiny-server.sh"),
            ("openclaw", "start-openclaw.sh"),
        ):
            self.assertEqual(config["program:" + name], {"command": "/usr/local/bin/" + command})
        self.assertEqual(routes, {"jupyter", "vscode", "rserver", "shiny", "openclaw"})
        settings = json.loads(jupyter)["ServerApp"]
        self.assertEqual(settings["port"], 8888)
        self.assertFalse(settings["open_browser"])

    def test_all_available_keeps_every_route_and_inherited_program(self):
        before, after, routes, _, _ = generate_config((*SERVICES, "hermes", "selkies"), inherited=True)
        config = parse_config(after)
        for section, settings in parse_config(before).items():
            self.assertEqual(config[section], settings)
        self.assertEqual(routes, set(ROUTES))
        self.assertEqual(config["inet_http_server"]["port"], ":9001")
        self.assertEqual(config["program-default"]["autostart"], "false")


# 每个组合独立报告，覆盖存在/不存在及仓库模板/代表性继承配置。
for hermes, selkies, inherited in itertools.product((False, True), repeat=3):
    def test(self, h=hermes, s=selkies, i=inherited):
        self.check_hermes_selkies(h, s, i)
    name = "test_hermes_{}_selkies_{}_inherited_{}".format(int(hermes), int(selkies), int(inherited))
    setattr(SupervisorConfigTests, name, test)


if __name__ == "__main__":
    unittest.main()
