#!/usr/bin/env python3
import sys, json, hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
ID, PORT = sys.argv[1], int(sys.argv[2])

class H(BaseHTTPRequestHandler):
    def reply(self, code, body, ctype="application/json", extra=None):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("X-Backend", ID)
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)
    def do_GET(self):
        if self.path == "/":
            self.reply(200, f"<h1>Backend {ID} is running</h1>", "text/html")
        elif self.path == "/api/status":
            self.reply(200, json.dumps({"backend": ID, "status": "ok"}),
                       extra={"Cache-Control": "no-store"})
        elif self.path == "/api/static":
            body = json.dumps({"message": "cacheable content"})
            etag = '"' + hashlib.md5(body.encode()).hexdigest() + '"'
            if self.headers.get("If-None-Match") == etag:
                self.send_response(304)
                self.send_header("ETag", etag)
                self.send_header("Cache-Control", "max-age=60")
                self.send_header("X-Backend", ID)
                self.end_headers()
            else:
                self.reply(200, body, extra={"Cache-Control": "max-age=60", "ETag": etag})
        else:
            self.reply(404, json.dumps({"error": "not found"}))
    do_HEAD = do_GET

ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()