"""A stdlib-only stand-in for an existing application: it serves the platform health contract
(/health/readiness on MANAGEMENT_PORT) and nothing else, so an E8 boot proves the IMAGE, not the app."""
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class _Health(BaseHTTPRequestHandler):
    def do_GET(self):
        ok = self.path in ("/", "/health/readiness", "/health/liveness")
        self.send_response(200 if ok else 404)
        self.end_headers()
        self.wfile.write(b"ok" if ok else b"not found")

    def log_message(self, *args):
        pass


def main():
    port = int(os.environ.get("SERVER_PORT") or os.environ.get("GRPC_PORT") or 8080)
    management = int(os.environ.get("MANAGEMENT_PORT") or port + 1)
    mgmt = ThreadingHTTPServer(("0.0.0.0", management), _Health)
    threading.Thread(target=mgmt.serve_forever, daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", port), _Health).serve_forever()
