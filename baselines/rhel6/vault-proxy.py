#!/usr/bin/env python3
"""Loopback-only caching proxy from the CentOS 6 guest to vault.centos.org.

Why: vault.centos.org (served through CloudFront) often cuts HTTPS
transfers short ("transfer closed with N bytes remaining", curl error 18)
or fails the TLS handshake; this happens from the host too. yum on CentOS 6
gives up on such a file after one try per baseurl, so large packages such
as gcc never finish, and TLS under TCG emulation is slow besides. This proxy fetches over the host's
modern TLS stack, caches each file under ``.cache/vault/`` and serves it to
the guest over plain HTTP.

Integrity: every package is still verified by yum (``gpgcheck=1`` against
the CentOS 6 and SCLo keys shipped in the guest), so plain HTTP between the
guest and this proxy does not weaken package authenticity.

Exposure: binds 127.0.0.1 only. QEMU user-mode networking maps the guest's
10.0.2.2 to the host loopback, so nothing is reachable from the network.
Only paths under the ``ALLOWED_PREFIXES`` are served.

Usage:
    vault-proxy.py [--port 8610] [--cache-dir DIR]
"""

from __future__ import annotations

import argparse
import os
import shutil
import sys
import tempfile
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

UPSTREAM = "https://vault.centos.org"
ALLOWED_PREFIXES = ("/6.10/os/", "/6.10/updates/", "/6.10/extras/", "/6.10/sclo/")
# Repository metadata changes name with content, but repomd.xml does not.
NO_CACHE_SUFFIXES = ("repomd.xml",)


class VaultHandler(BaseHTTPRequestHandler):
    """Serve allowed vault paths from the cache, filling it on a miss."""

    cache_dir: Path = Path(".")

    def do_GET(self) -> None:  # noqa: N802 (http.server naming)
        """Answer one GET request."""
        path = self.path.split("?", 1)[0]
        if ".." in path or not path.startswith(ALLOWED_PREFIXES):
            self.send_error(403, "path not allowed")
            return
        local = self.cache_dir / path.lstrip("/")
        cacheable = not path.endswith(NO_CACHE_SUFFIXES)
        if not (cacheable and local.is_file()):
            try:
                self._fetch(path, local)
            except urllib.error.HTTPError as exc:
                self.send_error(exc.code, str(exc.reason))
                return
            except (urllib.error.URLError, OSError) as exc:
                self.send_error(502, f"upstream error: {exc}")
                return
        size = local.stat().st_size
        self.send_response(200)
        self.send_header("Content-Length", str(size))
        self.send_header("Content-Type", "application/octet-stream")
        self.end_headers()
        with local.open("rb") as fh:
            shutil.copyfileobj(fh, self.wfile)

    def _fetch(self, path: str, local: Path) -> None:
        """Download ``UPSTREAM + path`` to ``local`` atomically, with retries."""
        local.parent.mkdir(parents=True, exist_ok=True)
        last: Exception | None = None
        for _ in range(12):
            fd, tmp = tempfile.mkstemp(dir=local.parent, prefix=".part-")
            try:
                with os.fdopen(fd, "wb") as out, urllib.request.urlopen(UPSTREAM + path, timeout=30) as resp:
                    expected = resp.headers.get("Content-Length")
                    shutil.copyfileobj(resp, out)
                if expected is not None and os.path.getsize(tmp) != int(expected):
                    raise OSError(f"short read for {path}")
                os.replace(tmp, local)
                return
            except urllib.error.HTTPError:
                os.unlink(tmp)
                raise
            except (urllib.error.URLError, OSError) as exc:
                last = exc
                if os.path.exists(tmp):
                    os.unlink(tmp)
        raise OSError(f"giving up on {path}: {last}")

    def log_message(self, fmt: str, *args: object) -> None:
        """Log one line per request to stderr."""
        sys.stderr.write("vault-proxy: " + (fmt % args) + "\n")


def main() -> int:
    """Parse arguments and serve forever on 127.0.0.1.

    Returns:
        Process exit status.
    """
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", type=int, default=8610)
    parser.add_argument("--cache-dir", type=Path, default=Path(__file__).resolve().parent / ".cache" / "vault")
    args = parser.parse_args()
    VaultHandler.cache_dir = args.cache_dir
    args.cache_dir.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), VaultHandler)
    sys.stderr.write(f"vault-proxy: serving {UPSTREAM} on 127.0.0.1:{args.port}, cache {args.cache_dir}\n")
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
