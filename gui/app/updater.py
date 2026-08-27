"""Self-update against GitHub Releases. Qt-free and testable.

Flow: check_latest() on startup (async, fails silent offline) -> if a newer
PUBLISHED release exists, the UI shows "Update Available" -> download the
platform asset -> apply (swap the install in place) -> relaunch.

macOS notes: extraction uses `ditto -x -k`, never Python's zipfile — the app
bundle contains symlinks and exec bits zipfile would destroy. The app
downloads the zip itself, so no com.apple.quarantine is attached and
Gatekeeper does not re-prompt after an update.
"""

from __future__ import annotations

import json
import os
import shutil
import ssl
import subprocess
import sys
import tempfile
import urllib.request

GITHUB_REPO = "yilmazdoga/rsyncronizer"
# Overridable so a failing update check can be reproduced against a local file,
# the same seam the CLI has as RBS_UPDATE_API_URL.
LATEST_URL = os.environ.get(
    "RBS_UPDATE_API_URL",
    f"https://api.github.com/repos/{GITHUB_REPO}/releases/latest")

# Why the last check found nothing. "" means it succeeded (or has not run).
#
# This exists because the check used to swallow every failure into the same
# `return None` as "you are up to date", which made a dead update button
# completely undiagnosable in the field -- see check_latest.
LAST_ERROR = ""


def _ssl_context() -> ssl.SSLContext:
    """A verifying TLS context that also works inside a frozen app.

    PyInstaller bundles libssl/libcrypto but NOT a trust store, and the bundled
    libcrypto is compiled to look for one at the BUILD machine's path --
    measured on the 0.3.0 macOS build:

        OPENSSLDIR = /Library/Frameworks/Python.framework/Versions/3.12/etc/openssl

    which does not exist on a user's Mac. The bundle carried zero .pem files and
    _ssl links only the bundled OpenSSL (no Apple Security framework), so there
    was nothing to fall back to: every HTTPS call raised
    SSLCertVerificationError and the update button silently never appeared.

    certifi ships the CA bundle inside the app, which removes the dependency on
    any path outside it. The OS store is the fallback for a source checkout.
    """
    try:
        import certifi

        return ssl.create_default_context(cafile=certifi.where())
    except Exception:
        pass
    ctx = ssl.create_default_context()
    try:
        if ctx.cert_store_stats().get("x509_ca", 0):
            return ctx
    except Exception:
        return ctx
    for path in ("/etc/ssl/cert.pem",                     # macOS
                 "/etc/ssl/certs/ca-certificates.crt",    # Debian/Ubuntu
                 "/etc/pki/tls/certs/ca-bundle.crt"):     # Fedora/RHEL
        if os.path.exists(path):
            try:
                ctx.load_verify_locations(cafile=path)
                break
            except Exception:
                continue
    return ctx


def _default_opener(req, timeout=6):
    """urlopen with an explicit trust store.

    Kept to the (req, timeout) shape the injected test openers use, so the
    context is a detail of the real path only."""
    return urllib.request.urlopen(req, timeout=timeout, context=_ssl_context())


def parse_version(text: str) -> tuple:
    """'v0.1.0' / '0.1.0' -> (0, 1, 0); unparseable parts become 0."""
    parts = []
    for chunk in text.strip().lstrip("vV").split("."):
        digits = "".join(c for c in chunk if c.isdigit())
        parts.append(int(digits) if digits else 0)
    return tuple(parts or [0])


def is_newer(candidate: str, current: str) -> bool:
    return parse_version(candidate) > parse_version(current)


def _platform_asset_marker() -> str:
    return "-macos-arm64.zip" if sys.platform == "darwin" else "-linux-x86_64.tar.gz"


def check_latest(current_version: str, opener=None) -> dict | None:
    """{'version': ..., 'asset_url': ..., 'asset_name': ...} when a newer
    release with a matching platform asset exists; None otherwise (including
    any network failure — an update check must never break startup)."""
    global LAST_ERROR
    LAST_ERROR = ""
    opener = opener or _default_opener
    try:
        req = urllib.request.Request(
            LATEST_URL, headers={"Accept": "application/vnd.github+json",
                                 "User-Agent": "rsyncronizer"})
        with opener(req, timeout=6) as resp:
            data = json.load(resp)
    except Exception as exc:
        # Record AND report. A silent failure here is indistinguishable from
        # "up to date", which is how a dead update button went unnoticed
        # through a whole release.
        LAST_ERROR = f"{type(exc).__name__}: {exc}"
        print(f"rsyncronizer: update check failed: {LAST_ERROR}", file=sys.stderr)
        return None
    tag = data.get("tag_name", "")
    if not tag:
        LAST_ERROR = "the release feed carried no tag_name"
        return None
    if not is_newer(tag, current_version):
        return None                      # genuinely up to date; not an error
    marker = _platform_asset_marker()
    for asset in data.get("assets", []):
        name = asset.get("name", "")
        if name.endswith(marker):
            return {"version": tag.lstrip("vV"),
                    "asset_url": asset.get("browser_download_url", ""),
                    "asset_name": name}
    LAST_ERROR = f"release {tag} has no asset ending in {marker}"
    print(f"rsyncronizer: update check: {LAST_ERROR}", file=sys.stderr)
    return None


def download(url: str, dest_dir: str, on_progress=None, opener=None) -> str:
    """Download url into dest_dir; returns the file path."""
    opener = opener or _default_opener
    path = os.path.join(dest_dir, url.rsplit("/", 1)[-1] or "asset")
    req = urllib.request.Request(url, headers={"User-Agent": "rsyncronizer"})
    with opener(req, timeout=30) as resp, open(path, "wb") as out:
        total = int(resp.headers.get("Content-Length") or 0)
        seen = 0
        while True:
            chunk = resp.read(1 << 16)
            if not chunk:
                break
            out.write(chunk)
            seen += len(chunk)
            if on_progress:
                on_progress(seen, total)
    return path


def install_target() -> str | None:
    """Where THIS running install lives.

    macOS: the enclosing .app bundle. Linux: the onedir directory holding the
    executable. None when running from source — nothing to self-update."""
    if not getattr(sys, "frozen", False):
        return None
    exe = os.path.realpath(sys.executable)
    if sys.platform == "darwin":
        node = exe
        while node and node != "/":
            if node.endswith(".app"):
                return node
            node = os.path.dirname(node)
        return None
    return os.path.dirname(exe)


def apply_update(archive_path: str, target: str) -> str:
    """Swap `target` for the copy inside the downloaded archive.

    The old install is moved aside (cleaned up on the next launch, see
    cleanup_leftovers) so a half-failed swap never leaves NO app. Returns the
    path to launch afterwards."""
    staging = tempfile.mkdtemp(prefix="rsyncronizer-update-")
    if archive_path.endswith(".zip"):
        subprocess.run(["ditto", "-x", "-k", archive_path, staging], check=True)
    else:
        subprocess.run(["tar", "-xzf", archive_path, "-C", staging], check=True)

    wanted = os.path.basename(target)
    fresh = None
    for dirpath, dirnames, _files in os.walk(staging):
        if wanted in dirnames:
            fresh = os.path.join(dirpath, wanted)
            break
    if fresh is None:
        raise RuntimeError(f"the downloaded archive does not contain {wanted}")

    old = target + ".old"
    if os.path.exists(old):
        shutil.rmtree(old, ignore_errors=True)
    os.rename(target, old)
    try:
        shutil.move(fresh, target)
    except Exception:
        os.rename(old, target)      # roll back: never leave no app at all
        raise
    return target


def relaunch(target: str) -> None:
    """Start the updated install; the caller quits afterwards."""
    if sys.platform == "darwin" and target.endswith(".app"):
        subprocess.Popen(["open", "-n", target])
    else:
        exe = os.path.join(target, os.path.basename(target))
        if not os.access(exe, os.X_OK):
            exe = os.path.join(target, "rsyncronizer")
        subprocess.Popen([exe], cwd=target)


def cleanup_leftovers() -> None:
    """Remove the previous version parked by apply_update, best effort."""
    target = install_target()
    if target and os.path.isdir(target + ".old"):
        shutil.rmtree(target + ".old", ignore_errors=True)
