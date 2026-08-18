# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

The release workflow extracts the matching `## [x.y.z]` section of this file
as the GitHub Release body, so keep each release's notes complete and
self-contained.

## [0.2.0] - 2026-08-18

### Support the author

- Rsyncronizer is completely free and will be so forever. If you find it
  useful, you can now buy the author a coffee:
  https://buymeacoffee.com/yilmazdoga
- The desktop app gets a small coffee button in the toolbar that opens the
  support dialog (where "Buy me a coffee" opens the page), and once every 10
  completed backups the same dialog appears on its own: type `i have supported` there
  (whether you did, or just do not want to see it) and it never returns on
  that machine; click Later and it comes back after 10 more backups. The
  terminal side prints the same reminder with a QR code after every 10th
  completed run, and `status` carries one plain line. New CLI command:
  `rsyncronizer support` (show the page and QR) and
  `rsyncronizer support --done` (the terminal way to silence it forever).
- Honor system throughout: nothing is verified, nothing is transmitted, no
  telemetry. The whole feature is one local gitignored file
  (`config/support.txt`) counting completed non-dry runs. Dry runs never
  count; scheduled and drive-connect runs count silently but are never
  interrupted; remote runs tick the remote machine's own counter. The
  reminder prints outside the run log and never affects exit codes
  (`RBS_NO_SUPPORT_NAG` suppresses it where the app streams engine output;
  it is presentational only and gates no safety mechanism).

## [0.1.0] - 2026-08-11

### Remote servers

- The app (and CLI) can now list, run, dry-run and even sync-delete backups
  that live on OTHER machines, over SSH (`remote.sh`). The UI groups backups
  into a LOCAL box plus one box per server; remote sync-deletions streams the
  remote engine's own preview and typed-confirmation prompt; all safeguards
  run server-side, and every ssh call is BatchMode-only (a broken key is a
  clean error, never a hang). Connection loss aborts safely: deletions only
  run after a completed transfer.

### SSH key setup

- `ssh-setup.sh [user@]host` (and a GUI dialog, also reachable from the
  wizard): generates an ed25519 key if needed, runs ssh-copy-id (you type
  the password once, masked in the GUI and never stored or echoed) and
  verifies the cron-equivalent no-agent path.

### GUI

- Progress: an activity bar with real counters (elapsed, ≈ files, current
  file, last run's total) replaces raw scroll; the full output sits behind a
  "Show output" dropdown. Never an invented percentage.
- The sync-deletions dialog is staged: scan → parsed will-delete list →
  typed phrase → re-verify → transfer, with raw output collapsible.
- The Refresh button is gone: a 30 s auto-refresh with a safe lifecycle
  (paused during runs and dialogs) replaces it.
- Self-update: the app checks GitHub Releases on startup; when a newer
  version is published, an "Update Available" button appears on the right of
  the toolbar; one click downloads the release, swaps the install in place
  (old version parked for rollback) and restarts. Because the app fetches
  its own update, macOS attaches no quarantine and Gatekeeper does not
  re-prompt.
- Ignore rules editor: the user-global layer, the shipped baseline
  (read-only) and per-backup excludes, editable in-app.

### CLI

- `rsyncronizer`: a dependency-free terminal front end over the same engine
  (status, new, run, dry, sync-deletions, remove, ignore, remote, ssh-setup,
  update), installable without the GUI via `install-cli.sh`; released as
  `rsyncronizer-cli-<ver>.tar.gz`. `remote <label> status` renders the same
  REMOTE: machine-name view as the app; `update` self-updates CLI-only
  installs from GitHub Releases.

### Engine

- Prune audit files renamed to `prune-<ts>-{preview,recheck}.log` with their
  own 10-slot ring; scans no longer occupy (or evict) run-log rotation
  slots, which is what made a scan look like a run.
- No hidden excludes: `config/global-exclude.txt` IS the global list:
  seeded once from the shipped defaults, fully visible and editable, and it
  replaces `rsync-ignore.txt` entirely (deleting a rule really un-excludes
  it). Excluded names are also shielded from sync-deletions.
- `last-run.txt` gains `HOW=` (what triggered the run) and `TOTAL_FILES=`;
  both surfaced by `status.sh --porcelain`.
- The engine file list is a single manifest (`lib/engine-manifest.txt`)
  consumed by the app, the build and the CLI installer alike.

## [0.0.1] - 2026-08-10

First release.

### Engine (bash)

- Append-only rsync backups over SSH or to a removable drive; nothing at a
  destination is ever deleted by a scheduled or plain run, enforced at runtime
  by a flag blacklist that also rejects unambiguous abbreviations.
- `setup.sh`: interactive wizard (and `--answers FILE` headless mode) that
  writes per-backup config, generates the runner, verifies SSH the way cron
  will, and installs cron/launchd/udev triggers.
- `status.sh`: health report (and `--porcelain` machine-readable mode) with
  staleness detection, drive-connect awareness, and exit-code verdicts.
- `--sync-deletions`: the one sanctioned deletion path: manual, interactive,
  preview + typed confirmation + re-verification, `--delete-after` only.
- Drive-connect backups: mount-point + marker double guard, cooldown,
  launchd/udev triggers; macOS Full Disk Access detection; exFAT handling.
- Test suite: 190+ checks against a stub rsync on macOS and Linux.

### GUI

- **Rsyncronizer**: standalone desktop apps for macOS (Apple Silicon) and
  Linux (x86_64), built with PySide6. Self-contained: the app materializes
  its own copy of the engine under `~/.local/share/rsync-backup-scripts/`.
- Wizard mirroring `setup.sh` (it drives the real script headlessly), and a
  status dashboard of collapsible per-backup cards (state, last run,
  human-readable schedule; expand for details). "Run manually" offers
  Dry run / Run / Run with sync deletions; the last streams the engine's
  deletion preview and requires typing `I confirm`, with the engine's own
  gate, recheck and exit codes unchanged. A "Delete backup schedule" button
  (backed by `setup.sh --remove NAME`) uninstalls the cron entry/trigger and
  removes config, logs and the runner, never the backed-up data.
- macOS app is unsigned: the first launch of a downloaded copy is blocked;
  open once, then System Settings → Privacy & Security → Open Anyway
  (one time; macOS 15+ removed the right-click→Open shortcut).

### CI/CD

- GitHub Actions: bash suite + GUI tests on macOS and Linux for every pull
  request and push to main; tag-driven release workflow that builds both
  apps and drafts a GitHub Release from this changelog.
