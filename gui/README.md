# Rsyncronizer

PySide6 desktop app for macOS and Linux (binary name `rsyncronizer`).
**It contains no backup logic**: every action is performed by the repo's
bash scripts:

| GUI action | What actually runs |
| --- | --- |
| New backup wizard | `setup.sh --answers <file>` (headless mode) |
| Status dashboard | `status.sh --porcelain` |
| Run manually → Dry run / Run | `backups/<name>.sh [--dry-run]` under a pty |
| Run manually → Run with sync deletions | `backups/<name>.sh --sync-deletions` under a pty |
| Delete backup schedule | `setup.sh --remove <name>` (cron/trigger + config + logs; backed-up data untouched) |
| Remote boxes + remote runs | `remote.sh <label> status\|run\|dry\|sync-deletions` |
| Set up SSH key access | `ssh-setup.sh [user@]host` (password forwarded masked, never stored) |
| Ignore rules editor | edits `config/global-exclude.txt` / per-backup `exclude.txt` |
| Destination page → account list | `lib/cloud.sh list` (`rclone listremotes`) |
| Connect an account… | `rclone config create <name> <type>` under a pty |

Cloud work goes through `lib/cloud.sh` rather than calling `rclone` from
Python, so the claim above stays literally true and the CLI and the app share
one code path.

The pty matters twice: without a terminal the engine logs only to file, and
the `--sync-deletions` confirmation requires one. The sync-deletions dialog
only streams the engine's preview and prompt and forwards the phrase the
user types; `I confirm` / `i confirm` matching, the post-confirmation
recheck, and the exit codes (75 = declined/changed) all live in the engine.
The GUI never auto-confirms.

The same pty is what lets a cloud sign-in work: rclone opens the browser
itself, and on a machine without one it prints a URL and waits for a pasted
token — the same prompt-and-forward shape the SSH dialog already uses. The
engine's confirmation marker (`engine.SYNC_DELETIONS_CONFIRMED`) is
transport-neutral, so the staged dialog is byte-identical for rsync and
rclone; `SYNC_DELETIONS_CONFIRMED_LEGACY` keeps the 0.2.x wording recognised,
because `remote.sh` drives a *remote* machine's engine that this app cannot
update.

## rclone

Bundled in the desktop apps (downloaded and checksum-verified at build time
from `lib/rclone-version.txt`, shipped through the manifest's `?bin/rclone`
optional entry, and `chmod +x`-ed by `materialize()` because PyInstaller's
`datas` drops the bit). It is **not** required: `engine.check_tools()`
deliberately lists only rsync and ssh, because a permanent red banner for a
dependency most users never need trains people to ignore banners. A missing
rclone surfaces in three narrower places instead — a blocking message on the
wizard's cloud page, a dashboard banner only when a cloud backup already
exists, and a per-card warning.

## Data layout

The app is self-contained. On first launch (and on version change) it
materializes the engine into

    ${XDG_DATA_HOME:-~/.local/share}/rsync-backup-scripts/

This is deliberately NOT `~/Library/Application Support`: that path contains a
space, which would end up inside generated crontab command lines. The engine
files are re-copied on every launch (a version gate was tried and caused
stale-engine bugs during same-version iteration); `config/`, `backups/` and
`logs/` in that tree are user state and are never touched.
`RSYNC_BACKUP_GUI_HOME` overrides the location (tests use this).

## Development

```bash
cd gui
python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
.venv/bin/python rsyncronizer.py            # run from source
QT_QPA_PLATFORM=offscreen .venv/bin/python -m pytest tests -q
.venv/bin/pyinstaller --noconfirm rsyncronizer.spec   # build
```

Layout: `app/engine.py` is Qt-free plumbing (materialization, pty runner with
a CONTROLLING terminal (ssh reads passwords from `/dev/tty`, so this is what
makes password forwarding possible at all), answers files, porcelain parsing,
remote/ssh-setup argv builders) and carries most of the test weight;
`app/status_view.py` (grouped boxes, staged sync-deletions dialog, refresh
lifecycle: 30 s timer paused during runs/dialogs, generation-tokened remote
fetches), `app/run_panel.py`, `app/dialogs.py`, `app/wizard.py`,
`app/main.py` are widgets. `rsyncronizer.py` is the PyInstaller entry point.
The engine file set lives in ONE place, `lib/engine-manifest.txt`, read by
engine.py, the spec, and `cli/install-cli.sh`. User state in the engine home
(`config/`, `backups/`, `logs/`, `remotes/`) is never touched by
materialization. The engine data directory stays
`~/.local/share/rsync-backup-scripts/` regardless of the app's display name:
installed crontab lines point into it, so it must never follow a rebrand.

`--self-check` runs without a display (materialize → `status.sh --porcelain`
→ summary → status exit code):

```bash
QT_QPA_PLATFORM=offscreen ./dist/rsyncronizer/rsyncronizer --self-check
```

## Headless answers keys

`setup.sh --answers FILE` takes KEY=VALUE lines; one key per prompt.
An absent key = pressing Enter (the prompt's default; for [y/N] confirms, N).

| Key | Prompt |
| --- | --- |
| `A_NAME` | backup name |
| `A_SOURCE` | source path |
| `A_DEST_KIND` | 1 = SSH, 2 = local drive, 3 = cloud (rclone) |
| `A_HOST`, `A_USER`, `A_DEST_PATH` | SSH destination (`A_USER=@none` forces a blank user) |
| `A_VOLUME_ROOT`, `A_DEST_PATH` | drive destination |
| `A_RCLONE_REMOTE`, `A_CLOUD_PROVIDER`, `A_DEST_PATH` | cloud destination. `A_RCLONE_REMOTE` names an rclone remote that must ALREADY exist — headless mode never creates one, and an unknown name exits 78. `A_DEST_PATH` is the path inside it; for S3 the bucket is its first segment. `A_CLOUD_PROVIDER` is setup.sh's menu number (1 = S3, 2 = Drive, 3 = OneDrive, 4 = Dropbox, 5 = other). |
| `A_CONFIRM_LANDING` | the "Is that correct?" gate; the GUI review page |
| `A_CREATE_DEST` | create a missing destination folder (SSH and cloud) |
| `A_EXCLUDE_OFFER`, `A_EXCLUDE_ADD`, `A_EXCLUDE_MORE` | exFAT exclude picker (GUI writes exclude.txt directly instead; at most ONE picker entry headless) |
| `A_RUN_DRY_RUN` | the wizard's embedded dry-run offer |
| `A_INSTALL_TRIGGER`, `A_TRIGMODE` | drive-connect trigger (1 = launchd, 2 = cron poll) |
| `A_SCHEDULE_YN`, `A_SCHEDULE_CHOICE`, `A_SCHEDULE_CUSTOM`, `A_CRON_CONFIRM` | cron scheduling chain (SSH and cloud) |

There are deliberately **no keys for cloud credentials**. An answers file is a
plain file on disk, and an access key does not belong in one: the app connects
the account first and passes only its name.
| `A_CRON_REMOVE` | remove an existing cron entry |
| `A_REMOVE` | the confirm for `setup.sh --remove NAME` (75 = declined) |

An invalid answer aborts with exit 78 naming the key, never an endless loop.
A failed cron install is exit 78 in headless mode, never silent success.
