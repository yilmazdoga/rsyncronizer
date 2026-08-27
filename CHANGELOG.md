# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

The release workflow extracts the matching `## [x.y.z]` section of this file
as the GitHub Release body, so keep each release's notes complete and
self-contained.

## [0.3.0] - 2026-08-27

### Cloud destinations

- A backup can now go to **Amazon S3 (and S3-compatible storage), Google
  Drive, OneDrive or Dropbox**, alongside the existing "another machine over
  SSH" and "a drive you plug in". Cloud backups are scheduled with cron like
  SSH ones and land by the same copy-by-name rule: `~/Documents` becomes
  `gdrive:Backups/laptop/Documents/`.
- rsync cannot reach any of those services, so this is a **second transport**
  rather than a new kind of rsync destination. It is [rclone](https://rclone.org),
  and which transport a backup uses is decided by its config and nothing else:
  every existing SSH and drive backup keeps working byte-for-byte unchanged.
- **The desktop apps bundle rclone** — nothing to install. It is pinned by
  version and SHA256 in `lib/rclone-version.txt` and verified at build time.
  That adds about 32 MB to each app download, including for people who never
  configure a cloud backup. The CLI and source checkouts use the system rclone
  (`brew install rclone` / `sudo apt install rclone`); the engine looks for its
  bundled copy first and falls through, so both work with no configuration.
- The wizard's Destination page gains a third choice with an account picker and
  a **Connect an account…** button: Google Drive, OneDrive and Dropbox open
  your browser to sign in (with a paste-a-token fallback for machines that have
  none), and S3 is a plain form. **Rsyncronizer stores no cloud credentials** —
  they go into rclone's own config, never into this project's config tree, its
  answers files or its logs. An S3 secret is written to `~/.aws/credentials`
  and the remote created with `env_auth=true`, so the key is never passed on a
  command line where `ps` could read it.
- The dashboard shows a cloud backup's account and provider, and warns when
  rclone is missing or when the account a backup names has disappeared. rclone
  is treated as genuinely optional: nothing mentions it until you configure, or
  already own, a cloud backup. `status.sh` makes no network calls at all — it
  runs from cron, where an expired sign-in must not be able to hang the health
  report.
- New CLI commands: `rsyncronizer cloud list` (accounts rclone knows about),
  `rsyncronizer cloud check <name>` (reachability, on demand — the one place
  that deliberately touches the network) and `rsyncronizer cloud login
  <remote>` (re-authorise an expired account).

### Deleting at the destination

- Every guarantee is unchanged, and now transport-neutral. A scheduled or plain
  cloud run is `rclone copy`, which has no code path that deletes anything.
  `rclone sync` is reachable only through the same gate as rsync's
  `--delete-after`: manual invocation, a real terminal, a preview, the typed
  phrase `I confirm`, and a re-verification afterwards. The desktop app still
  only forwards what you type.
- Two additions specific to the cloud path. `--max-delete` pins the confirmed
  count, so a run that somehow decided to remove more than you agreed to stops
  fatally. And because rclone reads an environment variable for **every** flag
  it has — `RCLONE_IGNORE_ERRORS=true` reaches the same switch as the
  command-line flag — every `RCLONE_*` variable is stripped before rclone runs,
  and each one removed is named in the log. A flag blacklist alone would have
  been decorative.
- The engine's confirmation line is now `deletions confirmed and re-verified`
  for both transports, with the mechanism logged separately. The app still
  recognises the old wording, so it can drive a remote machine that has not
  been updated yet.
- Note what "deleted" means per provider: Google Drive and OneDrive move
  entries to *their* trash, so space is reclaimed only when you empty it —
  which is also a 30-day safety net rsync never had.

### Known limits, worth reading before you rely on it

- No cloud service stores symlinks, ownership or permission bits, and no rclone
  flag changes that. Files come back as plain files owned by you.
- Google Drive caps uploads at 750 GB per day; a larger first backup simply
  continues the next day. OneDrive rejects paths over 400 characters and files
  over 250 GB, and its sign-in expires after 90 days of inactivity. Dropbox
  refuses some filenames and can only change a file's modification time by
  uploading it again. S3 reports no free-space figure, so the dashboard never
  shows one for it.
- An **encrypted** `rclone.conf` cannot be read by an unattended cron run.
  Setup warns about it, and a run fails fast rather than blocking forever at a
  prompt nobody sees.
- This release has been exercised against a real rclone, but not yet against a
  real S3, Drive, OneDrive or Dropbox account.

### Also

- `status.sh` now renders exit 69 as `UNAVAILABLE` rather than a bare
  `FAILED (69)`. It is the commonest non-zero code on a drive-connect backup,
  and now on a missing rclone.
- The engine manifest gained an optional-entry marker (`?bin/rclone`) so the
  bundled binary ships without a second, hard-coded copy of the engine file set
  appearing anywhere.
- The stale `gui/PR-NOTES.md` is removed.

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
