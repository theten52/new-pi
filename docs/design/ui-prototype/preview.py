#!/usr/bin/env python3
"""只提供原型白名单资源的本地预览服务器，不暴露项目或会话文件。"""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit


ROOT = Path(__file__).resolve().parent
REPOSITORY = ROOT.parents[2]
RESOURCES = {
    "/": (ROOT / "index.html", "text/html; charset=utf-8"),
    "/index.html": (ROOT / "index.html", "text/html; charset=utf-8"),
    "/prototype.css": (ROOT / "prototype.css", "text/css; charset=utf-8"),
    "/prototype.js": (ROOT / "prototype.js", "text/javascript; charset=utf-8"),
}
for name in ("markdown-it.min.js", "highlight.min.js"):
    RESOURCES[f"/NewPiApp/MarkdownRenderer/{name}"] = (
        REPOSITORY / "NewPiApp" / "MarkdownRenderer" / name,
        "text/javascript; charset=utf-8",
    )


class PreviewHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        resource = RESOURCES.get(urlsplit(self.path).path)
        if resource is None:
            self.send_error(404)
            return
        path, mime = resource
        try:
            content = path.read_bytes()
        except OSError:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(content)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "frame-ancestors 'none'")
        self.end_headers()
        self.wfile.write(content)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), PreviewHandler)
    print(f"NewPi UI prototype: http://127.0.0.1:{server.server_port}/", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()