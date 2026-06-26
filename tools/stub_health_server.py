#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import time


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/health":
            self.send_error(404)
            return

        body = json.dumps({"status": "ok", "version": "0.1.0-stub"}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != "/voice/full-romeo":
            self.send_error(404)
            return

        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        try:
            payload = json.loads(body.decode())
            text = payload.get("text", "")
        except Exception:
            self.send_error(400)
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()

        events = [
            ("status", {"value": "thinking"}),
            ("text", {"delta": "Stub Romeo heard: "}),
            ("text", {"delta": text}),
            ("status", {"value": "done"}),
        ]
        for event, data in events:
            self.wfile.write(f"event: {event}\n".encode())
            self.wfile.write(f"data: {json.dumps(data)}\n\n".encode())
            self.wfile.flush()
            time.sleep(0.2)

    def log_message(self, format, *args):
        print("%s - %s" % (self.address_string(), format % args))


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 8443), Handler)
    print("Stub Mini server listening at http://127.0.0.1:8443")
    server.serve_forever()
