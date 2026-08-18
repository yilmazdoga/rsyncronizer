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

The pty matters twice: without a terminal the engine logs only to file, and
the `--sync-deletions` confirmation requires one. The sync-deletions dialog
only streams the engine's preview and prompt and forwards the phrase the
user types; `I confirm` / `i confirm` matching, the post-confirmation
recheck, and the exit codes (75 = declined/changed) all live in the engine.
The GUI never auto-confirms.

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
| `A_DEST_KIND` | 1 = SSH, 2 = local drive |
| `A_HOST`, `A_USER`, `A_DEST_PATH` | SSH destination (`A_USER=@none` forces a blank user) |
| `A_VOLUME_ROOT`, `A_DEST_PATH` | drive destination |
| `A_CONFIRM_LANDING` | the "Is that correct?" gate; the GUI review page |
| `A_CREATE_DEST` | create a missing remote folder |
| `A_EXCLUDE_OFFER`, `A_EXCLUDE_ADD`, `A_EXCLUDE_MORE` | exFAT exclude picker (GUI writes exclude.txt directly instead; at most ONE picker entry headless) |
| `A_RUN_DRY_RUN` | the wizard's embedded dry-run offer |
| `A_INSTALL_TRIGGER`, `A_TRIGMODE` | drive-connect trigger (1 = launchd, 2 = cron poll) |
| `A_SCHEDULE_YN`, `A_SCHEDULE_CHOICE`, `A_SCHEDULE_CUSTOM`, `A_CRON_CONFIRM` | cron scheduling chain |
| `A_CRON_REMOVE` | remove an existing cron entry |
| `A_REMOVE` | the confirm for `setup.sh --remove NAME` (75 = declined) |

An invalid answer aborts with exit 78 naming the key, never an endless loop.
A failed cron install is exit 78 in headless mode, never silent success.
