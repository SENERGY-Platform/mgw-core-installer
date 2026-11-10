# Copyright (c) 2026 InfAI (CC SES)

# A caching mock of the GitHub API for the VM tests, so the host binaries' release archives (about
# 130 MiB) are downloaded once, not on every install. The installer uses it when MGW_TEST_GITHUB_API
# points at it (lib/net.sh).
#
#   python3 github_mock.py <port file> <cache dir>
#
# GET /repos/...        the API response, fetched from api.github.com the first time and cached; every
#                       asset's browser_download_url points to /download/<name> of this server
# GET /download/<name>  the asset, fetched from its real URL the first time and cached
#
# An error from GitHub (e.g. 404) is passed on and not cached. Writes its port to the port file once
# it listens, then serves until killed.

import hashlib
import json
import os
import shutil
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT_FILE, CACHE = sys.argv[1], sys.argv[2]
os.makedirs(os.path.join(CACHE, "api"), exist_ok=True)
os.makedirs(os.path.join(CACHE, "assets"), exist_ok=True)


def fetch(url, dest, headers=None):
    req = urllib.request.Request(url, headers=headers or {})
    tmp = dest + ".tmp"
    with urllib.request.urlopen(req, timeout=300) as resp, open(tmp, "wb") as f:
        shutil.copyfileobj(resp, f)
    os.replace(tmp, dest)


def remember_assets(data):
    releases = data if isinstance(data, list) else [data]
    for release in releases:
        for asset in release.get("assets", []):
            with open(os.path.join(CACHE, "assets", asset["name"] + ".url"), "w") as f:
                f.write(asset["browser_download_url"])


def rewrite(data, base):
    releases = data if isinstance(data, list) else [data]
    for release in releases:
        for asset in release.get("assets", []):
            asset["browser_download_url"] = base + "/download/" + asset["name"]
    return data


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, code, body, ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        base = "http://" + self.headers["Host"]
        try:
            if self.path.startswith("/repos/"):
                key = hashlib.sha1(self.path.encode()).hexdigest()
                cached = os.path.join(CACHE, "api", key + ".json")
                if not os.path.exists(cached):
                    fetch("https://api.github.com" + self.path, cached, {"Accept": "application/vnd.github+json"})
                    with open(cached) as f:
                        remember_assets(json.load(f))
                with open(cached) as f:
                    data = rewrite(json.load(f), base)
                self.send(200, json.dumps(data).encode())
            elif self.path.startswith("/download/"):
                name = os.path.basename(self.path)
                cached = os.path.join(CACHE, "assets", name)
                if not os.path.exists(cached):
                    with open(cached + ".url") as f:
                        fetch(f.read(), cached)
                with open(cached, "rb") as f:
                    self.send(200, f.read(), "application/octet-stream")
            else:
                self.send(404, b'{"message": "Not Found"}')
        except urllib.error.HTTPError as e:
            self.send(e.code, e.read())
        except FileNotFoundError:
            self.send(404, b'{"message": "Not Found"}')


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE, "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
