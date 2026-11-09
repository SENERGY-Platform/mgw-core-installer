# Copyright (c) 2026 InfAI (CC SES)

# A local HTTP server with fixed responses for the retry tests of lib/net.sh. Writes its port to the
# file given as the first argument, then serves until killed.
#
#   /ok                      200 "ok"
#   /status/<code>           that status
#   /github-ratelimit        403 with x-ratelimit-remaining: 0
#   /flaky/<id>/<n>          503 for the first n requests of <id>, then 200 "ok"
#   /count/<path>            200 with the number of requests seen so far for /status/<code>,
#                            /flaky/<id> or /github-ratelimit (e.g. /count/status/503)
#   /redirect                302 to /ok

import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

seen = {}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, body=b"", headers=()):
        self.send_response(code)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parts = self.path.strip("/").split("/")
        if parts[0] in ("flaky", "status", "github-ratelimit"):
            key = "/".join(parts[:2])
            seen[key] = seen.get(key, 0) + 1
        if parts[0] == "ok":
            self.reply(200, b"ok")
        elif parts[0] == "status":
            self.reply(int(parts[1]), b"error page")
        elif parts[0] == "github-ratelimit":
            self.reply(403, b"rate limit exceeded", [("x-ratelimit-remaining", "0")])
        elif parts[0] == "flaky":
            if seen["/".join(parts[:2])] <= int(parts[2]):
                self.reply(503, b"unavailable")
            else:
                self.reply(200, b"ok")
        elif parts[0] == "count":
            self.reply(200, str(seen.get("/".join(parts[1:3]), 0)).encode())
        elif parts[0] == "redirect":
            self.reply(302, b"", [("Location", "/ok")])
        else:
            self.reply(404, b"not found")


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
