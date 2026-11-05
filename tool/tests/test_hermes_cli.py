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

    def test_actual_websocket_upgrade_and_round_trip(self):
        import socket
        import threading
        import time
        import uvicorn
        from uvicorn.protocols.websockets.auto import AutoWebSocketsProtocol

        self.assertIsNotNone(AutoWebSocketsProtocol, "Hermes Dashboard 缺少 WebSocket 协议实现")
        from websockets.sync.client import connect

        async def echo(scope, receive, send):
            self.assertEqual(scope["type"], "websocket")
            self.assertEqual((await receive())["type"], "websocket.connect")
            await send({"type": "websocket.accept"})
            message = await receive()
            await send({"type": "websocket.send", "text": message["text"]})
            await send({"type": "websocket.close", "code": 1000})

        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        port = listener.getsockname()[1]
        server = uvicorn.Server(uvicorn.Config(echo, lifespan="off", log_level="error", access_log=False))
        thread = threading.Thread(target=server.run, kwargs={"sockets": [listener]}, daemon=True)
        thread.start()
        try:
            deadline = time.monotonic() + 5
            while not server.started and thread.is_alive() and time.monotonic() < deadline:
                time.sleep(.01)
            self.assertTrue(server.started)
            with connect(f"ws://127.0.0.1:{port}/", open_timeout=3, proxy=None) as client:
                client.send("native-websocket-probe")
                self.assertEqual(client.recv(timeout=3), "native-websocket-probe")
        finally:
            server.should_exit = True
            thread.join(timeout=5)
            listener.close()
        self.assertFalse(thread.is_alive())


    def test_actual_native_dashboard_pty_round_trip(self):
        import asyncio
        import time
        from hermes_cli.pty_bridge import PtyBridge

        self.assertTrue(PtyBridge.is_available(), "Hermes Dashboard 缺少原生PTY依赖")
        with PtyBridge.spawn([sys.executable, "-u", "-c", "print('native-pty-reply:' + input(), flush=True)"], env=dict(os.environ)) as bridge:
            self.assertTrue(asyncio.run(bridge.write(b"native-pty-probe\n", timeout=2)))
            output = b""
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                chunk = bridge.read(timeout=.1)
                if chunk is None:
                    break
                output += chunk
                if b"native-pty-reply:native-pty-probe" in output:
                    break
            self.assertIn(b"native-pty-reply:native-pty-probe", output)


if __name__ == "__main__": unittest.main()
