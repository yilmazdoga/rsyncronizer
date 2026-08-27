"""Engine plumbing for the rsync-backup GUI.

Everything in this module is deliberately Qt-free so it can be tested headless.
The GUI contains NO backup logic: every action shells out to the same bash
scripts the terminal user runs. This module only

  * materializes the bundled engine tree into the app's data directory,
  * writes answers files for `setup.sh --answers`,
  * parses `status.sh --porcelain` output,
  * runs engine subprocesses under a pty so their output streams live
    (without a tty, the engine logs only to file and panes would be blank).
"""

from __future__ import annotations

import configparser
import fcntl
import json
import os
import re
import pty
import select
import shutil
import subprocess
import sys
import tempfile
import termios

APP_DIR_NAME = "rsync-backup-scripts"


def manifest_entry(line: str) -> tuple[str, bool]:
    """Split a manifest line into (path, required).

    A leading '?' marks an OPTIONAL entry: ship it if it is there, skip it if
    it is not. It exists for bin/rclone, which is downloaded at build time and
    so is present in an app bundle but absent from the repo and from the CLI
    tarball. Keeping it in the manifest is what stops a second, hard-coded
    copy of the engine file set appearing -- the rule the bash suite enforces.
    """
    if line.startswith("?"):
        return line[1:], False
    return line, True


def engine_manifest() -> list[tuple[str, bool]]:
    """The engine file set as (path, required) pairs, from the single-source
    manifest.

    User state (config/, backups/, logs/, remotes/) is never in this list and
    never touched by materialization.
    """
    path = os.path.join(resource_root(), "lib", "engine-manifest.txt")
    entries = []
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#"):
                entries.append(manifest_entry(line))
    return entries


def engine_files() -> list[str]:
    """Just the paths, with the optional marker already stripped, so no caller
    can mistake '?bin/rclone' for a filename."""
    return [rel for rel, _ in engine_manifest()]


def resource_root() -> str:
    """Where the bundled engine files live.

    Frozen (PyInstaller): <_MEIPASS>/engine, filled by the .spec's datas.
    Development: the repo root, two levels above this file.
    """
    if getattr(sys, "frozen", False):
        return os.path.join(sys._MEIPASS, "engine")  # type: ignore[attr-defined]
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def engine_root() -> str:
    """The app's private engine tree.

    ~/.local/share on BOTH platforms, never ~/Library/Application Support:
    its space would end up inside generated crontab command lines and rsync
    paths, both of which are unquoted by design in the engine.
    RSYNC_BACKUP_GUI_HOME overrides for tests.
    """
    override = os.environ.get("RSYNC_BACKUP_GUI_HOME")
    if override:
        return override
    base = os.environ.get("XDG_DATA_HOME") or os.path.join(os.path.expanduser("~"), ".local", "share")
    return os.path.join(base, APP_DIR_NAME)


def _read_version(path: str) -> str:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def bundled_version() -> str:
    return _read_version(os.path.join(resource_root(), "VERSION"))


def materialize(force: bool = False) -> str:
    """Create or refresh the engine tree. Returns its root.

    Engine files are copied UNCONDITIONALLY -- nine small files, milliseconds.
    A VERSION gate was tried first and produced exactly the stale-engine bug
    it invited: same version, changed files, and the installed lib silently
    lagged the bundled one. The engine tree is app-managed; user state
    (config/, backups/, logs/) is never touched -- runners are
    version-independent shims by the engine's own design.
    """
    src = resource_root()
    dst = engine_root()
    for rel, required in engine_manifest():
        s = os.path.join(src, rel)
        d = os.path.join(dst, rel)
        if not required and not os.path.exists(s):
            continue
        os.makedirs(os.path.dirname(d), exist_ok=True)
        # Write beside the target and RENAME, never copy over it.
        #
        # copyfile truncates and rewrites the SAME inode, and bash reads a
        # script incrementally from a byte offset -- so replacing a script that
        # is currently running makes execution resume inside the NEW bytes.
        # This runs on EVERY launch, so a backup running at that moment would
        # have lib/common.sh swapped underneath it. (The CLI installer hit the
        # same thing for real on 0.2.0 -> 0.3.0: "syntax error near unexpected
        # token `('".) os.replace is an atomic rename: the new content gets a
        # new inode and any reader of the old one still sees it whole.
        tmp = d + ".rbs-new"
        shutil.copyfile(s, tmp)
        # bin/rclone rides in PyInstaller's datas, not binaries -- a static Go
        # binary must be copied verbatim rather than run through dependency
        # analysis -- and datas drops the executable bit. chmod BEFORE the
        # rename, so the file is never briefly non-executable.
        if (d.endswith(".sh")
                or os.path.basename(d) in ("rsyncronizer", "rclone")):
            os.chmod(tmp, 0o755)
        os.replace(tmp, d)
    ensure_global_exclude(dst)
    return dst


GLOBAL_EXCLUDE_HEADER = (
    "# Global excludes -- applied to EVERY backup on this machine.\n"
    "# This file IS the complete global list (seeded from the shipped\n"
    "# defaults; once it exists, rsync-ignore.txt no longer applies).\n"
    "# One rule per line, '- ' prefix, bare basenames. Deleting a line\n"
    "# un-excludes it. Excluded names are also protected from\n"
    "# sync-deletions at the destination.\n"
)


def ensure_global_exclude(root: str | None = None) -> str:
    """Seed config/global-exclude.txt from the shipped defaults, ONCE.

    Never overwrites: after seeding the file is user state, and editing it
    (including deleting rules) is the whole point — no hidden excludes."""
    root = root or engine_root()
    path = os.path.join(root, "config", "global-exclude.txt")
    if os.path.exists(path):
        return path
    os.makedirs(os.path.dirname(path), exist_ok=True)
    rules = []
    with open(os.path.join(root, "rsync-ignore.txt"), "r", encoding="utf-8") as fh:
        for line in fh:
            if line.strip() and not line.lstrip().startswith("#"):
                rules.append(line.rstrip("\n"))
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(GLOBAL_EXCLUDE_HEADER)
        fh.write("\n".join(rules) + "\n")
    return path


SUPPORT_URL = "https://buymeacoffee.com/yilmazdoga"

SUPPORT_HEADER = (
    "# Support-the-author state. Honor system, local only, never transmitted.\n"
)


def support_path() -> str:
    return os.path.join(engine_root(), "config", "support.txt")


def support_state() -> dict:
    """Parsed support state; a missing file or key defaults to zero/False.

    The engine's bash side owns the same file (config grammar); both writers
    emit the identical three keys so they round-trip each other."""
    state = {"supported": False, "run_count": 0, "last_nag_count": 0}
    try:
        with open(support_path(), "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, val = line.partition("=")
                key, val = key.strip(), val.strip()
                if key == "SUPPORTED":
                    state["supported"] = val == "yes"
                elif key == "RUN_COUNT" and val.isdigit():
                    state["run_count"] = int(val)
                elif key == "LAST_NAG_COUNT" and val.isdigit():
                    state["last_nag_count"] = int(val)
    except OSError:
        pass
    return state


def support_due() -> bool:
    s = support_state()
    return not s["supported"] and s["run_count"] - s["last_nag_count"] >= 10


def _write_support(supported: bool, run_count: int, last_nag_count: int) -> None:
    path = support_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = os.path.join(os.path.dirname(path), f".support.tmp.{os.getpid()}")
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(SUPPORT_HEADER)
        if supported:
            fh.write("SUPPORTED=yes\n")
        fh.write(f"RUN_COUNT={run_count}\n")
        fh.write(f"LAST_NAG_COUNT={last_nag_count}\n")
    os.replace(tmp, path)


def mark_supported() -> None:
    """Honor system, permanent; counters are preserved."""
    s = support_state()
    _write_support(True, s["run_count"], s["last_nag_count"])


def defer_support() -> None:
    """'Later': the next reminder comes 10 completed runs from now."""
    s = support_state()
    _write_support(s["supported"], s["run_count"], s["run_count"])


def check_tools() -> list[str]:
    """Names of required tools missing from PATH (empty list == all good)."""
    missing = []
    for tool in ("rsync", "ssh"):
        if shutil.which(tool) is None:
            missing.append(tool)
    return missing


# --------------------------------------------------------------------------
# Cloud destinations (rclone)
#
# rclone is OPTIONAL. check_tools() above deliberately does NOT list it: a
# permanent red banner for a dependency most users never need trains people to
# ignore banners. It is a problem only for a backup already configured to use
# it -- see rclone_missing_for_backups().
# --------------------------------------------------------------------------

CLOUD_TYPES = {
    "s3": "S3",
    "drive": "Google Drive",
    "onedrive": "OneDrive",
    "dropbox": "Dropbox",
}

# What will otherwise look like a bug the first time it happens.
CLOUD_PROVIDER_NOTES = {
    "s3": ("S3 reports no free-space figure, so the dashboard cannot show one. "
           "Reading a file's timestamp costs an extra request, so the first "
           "run is slow."),
    "drive": ("Google Drive caps uploads at 750 GB per day \u2014 a larger first "
              "backup continues the next day. Deletions go to Drive's trash, "
              "not straight to free space."),
    "onedrive": ("OneDrive rejects paths over 400 characters and files over "
                 "250 GB, and its sign-in expires after 90 days of no use. "
                 "Versioning can double the space a file uses."),
    "dropbox": ("Dropbox rejects some filenames outright, and can only change "
                "a file's modification time by uploading it again."),
}

CLOUD_NOTE_ALL = ("No cloud service stores symlinks, ownership or permission "
                  "bits. Files come back as plain files owned by you.")

# An rclone remote name. A name carrying ':' or '/' would silently re-point the
# destination once it is interpolated into 'remote:path', so it is validated
# here as well as in the engine.
RCLONE_NAME_RE = re.compile(r"^[A-Za-z0-9_.][A-Za-z0-9_.-]*$")


def rclone_path() -> str | None:
    """The rclone the ENGINE would pick, in the engine's own search order.

    The bundled copy wins: the desktop apps ship rclone and materialize it as
    bin/rclone, and a self-contained app should run the version it was built
    against rather than whatever the machine happens to have.
    """
    bundled = os.path.join(engine_root(), "bin", "rclone")
    if os.path.isfile(bundled) and os.access(bundled, os.X_OK):
        return bundled
    for candidate in ("/opt/homebrew/bin/rclone", "/usr/local/bin/rclone"):
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return shutil.which("rclone")


def rclone_version() -> str:
    """'1.75.0', or '' when rclone is absent or unreadable."""
    binary = rclone_path()
    if not binary:
        return ""
    try:
        out = subprocess.run([binary, "version"], capture_output=True,
                             text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return ""
    first = out.splitlines()[0] if out else ""
    match = re.match(r"^rclone\s+v?([0-9][0-9A-Za-z.\-]*)", first)
    return match.group(1) if match else ""


def _cloud_sh(*args: str) -> tuple[int, str]:
    """Run lib/cloud.sh, which is where every rclone invocation lives.

    Going through bash rather than calling rclone from Python is what keeps
    gui/README.md's claim -- "It contains no backup logic" -- literally true,
    and means the CLI and the app share one code path.
    """
    script = os.path.join(engine_root(), "lib", "cloud.sh")
    if not os.path.isfile(script):
        return 127, ""
    try:
        proc = subprocess.run(
            ["/bin/bash", "-c",
             f'REPO_ROOT="$1"; . "$1/lib/cloud.sh"; shift; "$@"',
             "_", engine_root(), *args],
            capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return 1, ""
    return proc.returncode, proc.stdout


def rclone_install_hint() -> str:
    """Per-OS install instructions, owned by bash so the app, the CLI and the
    engine cannot drift apart."""
    rc, out = _cloud_sh("rclone_install_hint")
    if rc == 0 and out.strip():
        return out.rstrip("\n")
    if sys.platform == "darwin":
        return ("Install rclone:  brew install rclone\n"
                "(or download it from https://rclone.org/downloads/ "
                "and put it on your PATH)")
    return ("Install rclone:  sudo apt install rclone     (Debian/Ubuntu)\n"
            "                 sudo dnf install rclone     (Fedora)\n"
            "                 sudo pacman -S rclone       (Arch)")


def list_cloud_remotes() -> list[dict]:
    """The rclone accounts this machine knows about, as
    [{"name", "type", "description"}], filtered to the four supported types.

    Returns [] and never raises when rclone is absent -- the caller is usually
    painting a page, not performing an operation.
    """
    binary = rclone_path()
    if not binary:
        return []
    remotes: list[dict] = []
    try:
        proc = subprocess.run([binary, "listremotes", "--json"],
                              capture_output=True, text=True, timeout=15)
        if proc.returncode == 0 and proc.stdout.strip():
            for item in json.loads(proc.stdout):
                remotes.append({
                    "name": str(item.get("name", "")).rstrip(":"),
                    "type": str(item.get("type", "")),
                    "description": str(item.get("description", "")),
                })
    except (OSError, subprocess.SubprocessError, ValueError):
        remotes = []
    if not remotes:
        # --json is recent; the rclone in Ubuntu's archive predates it, and
        # that is exactly this audience. --long is "name: type description".
        try:
            proc = subprocess.run([binary, "listremotes", "--long"],
                                  capture_output=True, text=True, timeout=15)
        except (OSError, subprocess.SubprocessError):
            return []
        if proc.returncode != 0:
            return []
        for line in proc.stdout.splitlines():
            if ":" not in line:
                continue
            name, _, rest = line.partition(":")
            parts = rest.split()
            remotes.append({
                "name": name.strip(),
                "type": parts[0] if parts else "",
                "description": " ".join(parts[1:]),
            })
    return [r for r in remotes if r["type"] in CLOUD_TYPES]


def cloud_remote_type(name: str) -> str:
    for remote in list_cloud_remotes():
        if remote["name"] == name:
            return remote["type"]
    return ""


def rclone_missing_for_backups(backups: list[dict]) -> bool:
    """rclone is optional: its absence is a PROBLEM only once a backup depends
    on it. check_tools() deliberately does not list it."""
    if rclone_path() is not None:
        return False
    return any(b.get("DEST_TYPE") == "cloud" for b in backups)


def cloud_dest_path(form: dict) -> str:
    """The path inside the remote, with an S3 bucket folded in as its first
    segment.

    rclone's own model is remote:path where the bucket is just segment one, so
    a separate config key would be meaningless for three of the four providers
    and would make DEST_PATH mean different things per provider. The wizard
    still shows a separate labelled FIELD, so an S3 user is told a bucket is
    required rather than failing opaquely.
    """
    parts = [str(form.get("cloud_bucket", "") or "").strip("/ "),
             str(form.get("dest_path", "") or "").strip("/ ")]
    return "/".join(p for p in parts if p)


def write_aws_profile(profile: str, access_key: str, secret_key: str,
                      region: str = "", path: str | None = None) -> str:
    """Store S3 credentials in ~/.aws/credentials under a named profile.

    This exists to keep the secret OFF THE COMMAND LINE. `rclone config create`
    takes option values as arguments, so the obvious
    `secret_access_key=...` form exposes a long-lived AWS key to any `ps` on
    the machine for the life of the call. rclone's own `env_auth=true` +
    `profile=` reads the standard AWS shared-credentials file instead, which is
    both the idiomatic answer and one we can write with no subprocess at all.

    An existing profile of the same name is never overwritten silently -- the
    caller gets False from profile_exists() first and decides.
    """
    path = path or os.path.join(os.path.expanduser("~"), ".aws", "credentials")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    parser = configparser.RawConfigParser()
    if os.path.exists(path):
        parser.read(path)
    if not parser.has_section(profile):
        parser.add_section(profile)
    parser.set(profile, "aws_access_key_id", access_key)
    parser.set(profile, "aws_secret_access_key", secret_key)
    if region:
        parser.set(profile, "region", region)
    # Write through a 0600 temp file: the destination must never exist, even
    # briefly, with default permissions.
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".credentials-")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            parser.write(fh)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    os.chmod(path, 0o600)
    return path


def aws_profile_exists(profile: str, path: str | None = None) -> bool:
    path = path or os.path.join(os.path.expanduser("~"), ".aws", "credentials")
    if not os.path.exists(path):
        return False
    parser = configparser.RawConfigParser()
    try:
        parser.read(path)
    except configparser.Error:
        return False
    return parser.has_section(profile)


def cloud_config_argv(name: str, rtype: str, options: dict) -> list[str]:
    """argv for `rclone config create`. NEVER carries a secret -- see
    write_aws_profile for why S3 credentials take the AWS-profile route."""
    binary = rclone_path() or "rclone"
    argv = [binary, "config", "create", name, rtype]
    for key, value in options.items():
        argv.append(f"{key}={value}")
    return argv


def cloud_config_runner(name: str, rtype: str, options: dict | None = None) -> PtyRunner:
    """A not-yet-started PtyRunner for `rclone config create`.

    Under the pty rclone opens the browser itself for the OAuth backends, and
    can prompt for a pasted token on a machine with no browser -- the same
    prompt-and-forward shape SshSetupDialog already uses. The caller starts it
    in a thread.
    """
    return PtyRunner(cloud_config_argv(name, rtype, options or {}))


def cloud_dest_display(form: dict) -> str:
    """rclone's canonical remote:path -- the same string status.sh reports, and
    paste-able straight into an `rclone ls`."""
    return f"{form.get('cloud_remote', '')}:{cloud_dest_path(form)}"


# --------------------------------------------------------------------------
# Answers files
# --------------------------------------------------------------------------

# setup.sh's own menu order for the provider prompt.
_CLOUD_PROVIDER_ANSWER = {"s3": "1", "drive": "2", "onedrive": "3", "dropbox": "4"}


def build_answers(form: dict) -> dict:
    """Map wizard form state to setup.sh --answers keys.

    The review page of the wizard IS the landing confirmation, so
    A_CONFIRM_LANDING is always yes. The GUI never uses the interactive
    exclude picker (it edits config/<name>/exclude.txt directly), and the
    dry-run button replaces the wizard's embedded dry-run offer.
    """
    answers = {
        "A_NAME": form["name"],
        "A_SOURCE": form["source"],
        "A_CONFIRM_LANDING": "yes",
        "A_RUN_DRY_RUN": "n",
    }
    if form["dest_kind"] == "ssh":
        answers["A_DEST_KIND"] = "1"
        answers["A_HOST"] = form["host"]
        # Absent key means "accept the ssh -G prefill"; the GUI field is
        # explicit, so an empty field must force a blank user.
        answers["A_USER"] = form.get("user") or "@none"
        answers["A_DEST_PATH"] = form["dest_path"]
        answers["A_CREATE_DEST"] = "y" if form.get("create_dest", True) else "n"
        if form.get("schedule"):
            answers["A_SCHEDULE_YN"] = "y"
            answers["A_SCHEDULE_CHOICE"] = form["schedule_choice"]
            if form["schedule_choice"] == "5":
                answers["A_SCHEDULE_CUSTOM"] = form["schedule_custom"]
            answers["A_CRON_CONFIRM"] = "y"
    elif form["dest_kind"] == "cloud":
        answers["A_DEST_KIND"] = "3"
        answers["A_RCLONE_REMOTE"] = form["cloud_remote"]
        answers["A_CLOUD_PROVIDER"] = _CLOUD_PROVIDER_ANSWER.get(
            form.get("cloud_type", ""), "5")
        answers["A_DEST_PATH"] = cloud_dest_path(form)
        answers["A_CREATE_DEST"] = "y" if form.get("create_dest", True) else "n"
        # Cloud backups are cron-scheduled exactly like SSH ones.
        if form.get("schedule"):
            answers["A_SCHEDULE_YN"] = "y"
            answers["A_SCHEDULE_CHOICE"] = form["schedule_choice"]
            if form["schedule_choice"] == "5":
                answers["A_SCHEDULE_CUSTOM"] = form["schedule_custom"]
            answers["A_CRON_CONFIRM"] = "y"
    else:
        answers["A_DEST_KIND"] = "2"
        answers["A_VOLUME_ROOT"] = form["volume_root"]
        answers["A_DEST_PATH"] = form["dest_path"]
        if form.get("install_trigger"):
            answers["A_INSTALL_TRIGGER"] = "y"
            answers["A_TRIGMODE"] = form.get("trigmode", "2")
            answers["A_CRON_CONFIRM"] = "y"  # the macOS cron-poll trigger
    return answers


def write_answers(answers: dict, root: str | None = None) -> str:
    """Write an answers file (0600) and return its path."""
    root = root or engine_root()
    os.makedirs(root, exist_ok=True)
    fd, path = tempfile.mkstemp(prefix=".answers-", suffix=".txt", dir=root)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        for key, value in answers.items():
            fh.write(f"{key}={value}\n")
    os.chmod(path, 0o600)
    return path


# --------------------------------------------------------------------------
# Subprocesses
# --------------------------------------------------------------------------

class PtyRunner:
    """An engine subprocess on a pty, with a thread-safe way to type into it.

    The pty matters twice over: the engine's log() prints to the terminal only
    when stdout is a tty, and the --sync-deletions confirmation REQUIRES a
    terminal on stdin and stdout — under this runner the engine's own gate,
    preview, typed-phrase check and post-confirmation re-verification all run
    exactly as they do in a real terminal. The GUI only forwards what the
    user typed; it never confirms by itself.
    """

    # A prompt has no trailing newline, so line-based delivery would sit on it
    # forever. Flush the partial buffer when it ends like a prompt.
    _PROMPT_TAILS = (b": ", b"? ")

    def __init__(self, argv: list[str], cwd: str | None = None):
        self._argv = argv
        self._cwd = cwd
        self._master: int | None = None
        self._proc: subprocess.Popen | None = None

    def send(self, text: str) -> None:
        """Type into the child's terminal (call from any thread)."""
        if self._master is not None:
            os.write(self._master, text.encode("utf-8"))

    def terminate(self) -> None:
        if self._proc is not None and self._proc.poll() is None:
            self._proc.terminate()

    def run(self, on_line=None) -> int:
        """Blocking read loop; returns the exit code. Run me in a thread."""
        master, slave = pty.openpty()
        self._master = master
        try:
            # start_new_session + TIOCSCTTY make the pty the child's
            # CONTROLLING terminal, not just its stdio. ssh reads passwords
            # from /dev/tty, which only exists for the child if this is done;
            # without it, password prompts land in the launching terminal (or
            # nowhere) instead of this stream. The ioctl targets fd 0, which
            # is the pty slave after the dup2s; the preexec body is a single
            # syscall, safe in the forked child.
            self._proc = subprocess.Popen(
                self._argv,
                stdin=slave,
                stdout=slave,
                stderr=slave,
                cwd=self._cwd,
                close_fds=True,
                start_new_session=True,
                preexec_fn=lambda: fcntl.ioctl(0, termios.TIOCSCTTY, 0),
            )
        finally:
            os.close(slave)

        buf = b""

        def deliver(data: bytes) -> None:
            if on_line is None:
                return
            text = data.decode("utf-8", errors="replace").rstrip("\r")
            on_line(text)

        try:
            while True:
                try:
                    ready, _, _ = select.select([master], [], [], 0.2)
                except InterruptedError:
                    continue
                if ready:
                    try:
                        chunk = os.read(master, 4096)
                    except OSError:
                        break  # EIO: the child closed its side
                    if not chunk:
                        break
                    buf += chunk
                    while b"\n" in buf:
                        line, buf = buf.split(b"\n", 1)
                        deliver(line)
                    if buf and buf.endswith(self._PROMPT_TAILS):
                        deliver(buf)
                        buf = b""
                elif self._proc.poll() is not None:
                    break
            if buf:
                deliver(buf)
        finally:
            self._master = None
            os.close(master)
        return self._proc.wait()


def run_streaming(argv: list[str], on_line=None, cwd: str | None = None) -> int:
    """One-shot convenience over PtyRunner for non-interactive runs."""
    return PtyRunner(argv, cwd=cwd).run(on_line=on_line)


def run_setup(answers: dict, on_line=None) -> int:
    """Drive the real setup.sh headlessly, streaming its transcript."""
    root = materialize()
    path = write_answers(answers, root)
    try:
        return run_streaming(
            ["/bin/bash", os.path.join(root, "setup.sh"), "--answers", path],
            on_line=on_line,
            cwd=root,
        )
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def run_backup(name: str, dry_run: bool = False, on_line=None) -> int:
    """Run a backup (or dry run) via its generated runner, streaming output."""
    root = engine_root()
    argv = ["/bin/bash", os.path.join(root, "backups", f"{name}.sh")]
    if dry_run:
        argv.append("--dry-run")
    return run_streaming(argv, on_line=on_line, cwd=root)


def remove_backup(name: str, on_line=None) -> int:
    """Delete a backup SCHEDULE via `setup.sh --remove`: cron entry/trigger,
    config, logs and runner on this machine. The backed-up data is never
    touched -- the engine's removal branch does not construct destination
    paths at all. The A_REMOVE answer is supplied because the GUI shows its
    own confirmation dialog first."""
    root = materialize()
    path = write_answers({"A_REMOVE": "y"}, root)
    try:
        return run_streaming(
            ["/bin/bash", os.path.join(root, "setup.sh"), "--remove", name,
             "--answers", path],
            on_line=on_line,
            cwd=root,
        )
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


# The engine's confirmation prompt, verbatim; the GUI enables its input box
# when this appears in the stream.
SYNC_DELETIONS_PROMPT = "Type 'I confirm' to delete these"

# The engine's marker that the confirmation was accepted and re-verified.
# Deliberately transport-neutral: the SAME line for rsync and for rclone. The
# mechanism (--delete-after, or rclone sync) is logged on the NEXT line, which
# nothing here classifies.
SYNC_DELETIONS_CONFIRMED = "deletions confirmed and re-verified"

# Engines older than 0.3.0 said this instead. Not optional: remote.sh drives a
# REMOTE machine's engine, which this app cannot update, and the handshake
# refuses only engines with no VERSION file at all. Without this alias a
# sync-deletions run against a 0.2.x server would stall at "re-verifying"
# forever.
SYNC_DELETIONS_CONFIRMED_LEGACY = "confirmed; --delete-after enabled"


def looks_like_password_prompt(line: str) -> bool:
    """ssh/ssh-copy-id password or passphrase prompts. The reply to one of
    these must be masked and never echoed anywhere."""
    lowered = line.strip().lower()
    return lowered.endswith(":") and ("password" in lowered or "passphrase" in lowered)


# --------------------------------------------------------------------------
# Remote servers (all logic in remote.sh; these are thin argv builders)
# --------------------------------------------------------------------------

def _remote_argv(*args: str) -> list[str]:
    root = materialize()
    return ["/bin/bash", os.path.join(root, "remote.sh"), *args]


def list_remotes() -> list[dict]:
    """[{label, host, path}] from `remote.sh list`."""
    proc = subprocess.run(_remote_argv("list"), capture_output=True, text=True,
                          cwd=engine_root())
    remotes = []
    for line in proc.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) == 3:
            remotes.append({"label": parts[0], "host": parts[1], "path": parts[2]})
    return remotes


def add_remote(label: str, host: str, path: str) -> tuple[int, str]:
    proc = subprocess.run(_remote_argv("add", label, host, path),
                          capture_output=True, text=True, cwd=engine_root())
    return proc.returncode, (proc.stdout + proc.stderr).strip()


def remove_remote(label: str) -> tuple[int, str]:
    proc = subprocess.run(_remote_argv("rm", label),
                          capture_output=True, text=True, cwd=engine_root())
    return proc.returncode, (proc.stdout + proc.stderr).strip()


def remote_status(label: str) -> tuple[int, dict, list[dict], str]:
    """(exit, header, backups, error_text) for one remote."""
    proc = subprocess.run(_remote_argv(label, "status"), capture_output=True,
                          text=True, cwd=engine_root())
    header, backups = parse_porcelain(proc.stdout)
    error = "" if backups or proc.returncode == 0 else \
        (proc.stderr.strip() or proc.stdout.strip() or f"exit {proc.returncode}")
    return proc.returncode, header, backups, error


def remote_runner(label: str, mode: str, name: str) -> PtyRunner:
    """A PtyRunner for remote run|dry|sync-deletions, not yet started."""
    return PtyRunner(_remote_argv(label, mode, name), cwd=engine_root())


def remote_title(host: str, hostname: str | None = None) -> str:
    """Display name for a remote: always the MACHINE's name, deduced from the
    fetched porcelain HOSTNAME when available. A remote registered by IP (or
    an alias that differs from the real hostname) shows the registration in
    parentheses: 'REMOTE: backup-server  (192.168.1.50)'."""
    bare = host.split("@")[-1]
    if hostname:
        short = hostname.split(".")[0]
        if short and short != bare:
            return f"REMOTE: {short}  ({bare})"
        return f"REMOTE: {short or bare}"
    return f"REMOTE: {bare}"


def ssh_setup_runner(target: str) -> PtyRunner:
    """A PtyRunner for ssh-setup.sh, not yet started."""
    root = materialize()
    return PtyRunner(["/bin/bash", os.path.join(root, "ssh-setup.sh"), target],
                     cwd=root)


def sync_deletions_runner(name: str) -> PtyRunner:
    """A PtyRunner for `<runner> --sync-deletions`, NOT yet started.

    The caller runs it in a thread, watches for SYNC_DELETIONS_PROMPT, and
    forwards the phrase the user typed via .send(). Exit codes are the
    engine's: 0 done, 75 declined or list-changed, others as any run.
    """
    root = engine_root()
    argv = ["/bin/bash", os.path.join(root, "backups", f"{name}.sh"), "--sync-deletions"]
    return PtyRunner(argv, cwd=root)


# --------------------------------------------------------------------------
# Human-readable schedules
# --------------------------------------------------------------------------

def humanize_schedule(backup: dict) -> str:
    """A porcelain block -> 'every day at 02:00' style text."""
    sched = backup.get("SCHEDULE", "")
    local = backup.get("DEST_TYPE") == "local"
    if backup.get("TRIGGER") == "1":
        return "on drive connect"
    if not sched:
        return "manual runs only"
    parts = sched.split()
    if len(parts) != 5:
        return sched
    minute, hour, dom, mon, dow = parts

    def hhmm(h: str, m: str) -> str:
        try:
            return f"{int(h):02d}:{int(m):02d}"
        except ValueError:
            return f"{h}:{m}"

    if minute.startswith("*/") and hour == dom == mon == dow == "*":
        text = f"every {int(minute[2:])} min"
        # The macOS drive-connect fallback is a cron poll: what it MEANS is
        # "when the drive is connected", the poll is just the mechanism.
        return f"on drive connect (checked {text})" if local else text
    if dow != "*" and hour != "*" and minute != "*":
        days = {"0": "Sunday", "1": "Monday", "2": "Tuesday", "3": "Wednesday",
                "4": "Thursday", "5": "Friday", "6": "Saturday", "7": "Sunday"}
        day = days.get(dow, dow)
        return f"every {day} at {hhmm(hour, minute)}"
    if "," in hour and minute != "*":
        times = ", ".join(hhmm(h, minute) for h in hour.split(","))
        return f"daily at {times}"
    if hour != "*" and minute != "*" and dom == mon == dow == "*":
        return f"every day at {hhmm(hour, minute)}"
    if hour == "*" and minute != "*":
        return f"hourly at :{int(minute):02d}" if minute.isdigit() else sched
    return sched


def humanize_age(epoch: str, now: float | None = None) -> str:
    """'2h ago' from a LAST_EPOCH value; '' if unparseable."""
    import time as _time

    try:
        age = int(now if now is not None else _time.time()) - int(epoch)
    except (TypeError, ValueError):
        return ""
    if age < 0:
        return ""
    if age < 3600:
        return f"{age // 60}m ago"
    if age < 86400:
        return f"{age // 3600}h ago"
    return f"{age // 86400}d ago"


# --------------------------------------------------------------------------
# Status
# --------------------------------------------------------------------------

def parse_porcelain(text: str) -> tuple[dict, list[dict]]:
    """Parse `status.sh --porcelain` into (header, [backup, ...])."""
    header: dict = {}
    backups: list[dict] = []
    current: dict | None = None
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            if current is not None:
                backups.append(current)
                current = None
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key == "BACKUP":
            if current is not None:
                backups.append(current)
            current = {"BACKUP": value}
        elif current is not None:
            current[key] = value
        else:
            header[key] = value
    if current is not None:
        backups.append(current)
    return header, backups


def status() -> tuple[int, dict, list[dict]]:
    """Run status.sh --porcelain. Returns (exit_code, header, backups)."""
    root = materialize()
    proc = subprocess.run(
        ["/bin/bash", os.path.join(root, "status.sh"), "--porcelain"],
        capture_output=True,
        text=True,
        cwd=root,
    )
    header, backups = parse_porcelain(proc.stdout)
    return proc.returncode, header, backups


def self_check() -> int:
    """--self-check: materialize, run porcelain status, print it, exit code.

    Used to verify a build on a machine without a display.
    """
    root = materialize()
    print(f"engine root : {root}")
    print(f"version     : {bundled_version()}")
    missing = check_tools()
    if missing:
        print(f"MISSING tools: {' '.join(missing)}")
    rc, header, backups = status()
    print(f"rsync       : {header.get('RSYNC_BIN', '?')} ({header.get('RSYNC_FLAVOUR', '?')})")
    # Cheapest place to catch a packaging mistake: the release workflow runs
    # --self-check against both frozen binaries.
    rclone = rclone_path()
    if rclone:
        print(f"rclone      : {rclone} ({rclone_version() or '?'})")
    else:
        print("rclone      : not installed (optional; only cloud backups need it)")
    print(f"backups     : {len(backups)} configured")
    for b in backups:
        print(f"  - {b.get('BACKUP')}: {b.get('VERDICT', 'never ran' if b.get('NEVER_RAN') == '1' else '?')}")
    print(f"status exit : {rc}")
    return rc
