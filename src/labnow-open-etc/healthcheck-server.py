#!/usr/bin/env python3
"""Simple HTTP health check server for spawner compatibility."""
import http.server
import json

class HealthHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"status": "ok"}).encode())

    def log_message(self, format, *args):
        pass  # Suppress logs

if __name__ == "__main__":
    server = http.server.HTTPServer(("0.0.0.0", 8888), HealthHandler)
    server.serve_forever()
