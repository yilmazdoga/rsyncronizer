<p align="center">
  <img src="gui/assets/icon-256.png" width="128" alt="Rsyncronizer app icon">
</p>

# Rsyncronizer

Append-only rsync backups over SSH: engine, desktop apps and CLI. Install it
on each machine you back up **from** (see *Install* below), or clone this
repo and run it in place. Destinations need nothing installed beyond SSH and
rsync.

```
laptop (macOS)  ──►  backup-server (Linux)  ──►  nas (Synology)
  ~/Documents          ~/backups                  /volume1/backups/
```

**Nothing is ever deleted at a destination by a scheduled or plain run.** Remove
a file at the source and it stays at the destination until you delete it there
yourself, or until you explicitly ask for `--sync-deletions` run (see *Deleting at the destination* below). This is enforced
at runtime, not just by convention; see *Safety*.

## Install

Every build is on the
[Releases page](https://github.com/yilmazdoga/rsyncronizer/releases/latest):
a desktop app for macOS and Linux, and a headless CLI for any machine with
bash. All forms need `rsync` and `ssh` on the machine; macOS ships both, on
Linux run `sudo apt install rsync openssh-client`.

### Desktop app on macOS (Apple silicon)

Download `rsyncronizer-<version>-macos-arm64.zip` from Releases, unzip it and
drag `Rsyncronizer.app` into `/Applications`. The first launch of a
downloaded copy is blocked because the app is unsigned: double-click it once,
then System Settings → Privacy and Security → **Open Anyway**. Terminal
alternative:

```bash
xattr -dr com.apple.quarantine /Applications/Rsyncronizer.app
```

That is needed one time only. Afterwards the app updates itself: it checks
on startup and shows an **Update Available** button when a new release is
out.

### Desktop app on Linux (x86_64)

Needs glibc 2.35 or newer (Ubuntu 22.04+) and a desktop session. This
installs per-user, no root needed, and puts Rsyncronizer in your app menu:

```bash
ver=$(curl -fsSL https://api.github.com/repos/yilmazdoga/rsyncronizer/releases/latest | sed -n 's/.*"tag_name": *"v//p' | sed 's/".*//')
curl -fsSLO "https://github.com/yilmazdoga/rsyncronizer/releases/download/v${ver}/rsyncronizer-${ver}-linux-x86_64.tar.gz"
tar -xzf "rsyncronizer-${ver}-linux-x86_64.tar.gz"
"./rsyncronizer-${ver}-linux-x86_64/install.sh"
```

Prefer not to install? Extract and run it in place:
`./rsyncronizer-<version>-linux-x86_64/rsyncronizer/rsyncronizer`.

### CLI on macOS or Linux (no GUI)

One tarball works on both systems; it is plain bash. This installs the
engine to `~/.local/share/rsync-backup-scripts/` and the `rsyncronizer`
command to `~/.local/bin/` (make sure that is on your `PATH`):

```bash
ver=$(curl -fsSL https://api.github.com/repos/yilmazdoga/rsyncronizer/releases/latest | sed -n 's/.*"tag_name": *"v//p' | sed 's/".*//')
curl -fsSLO "https://github.com/yilmazdoga/rsyncronizer/releases/download/v${ver}/rsyncronizer-cli-${ver}.tar.gz"
tar -xzf "rsyncronizer-cli-${ver}.tar.gz"
"./rsyncronizer-cli-${ver}/install-cli.sh"
```

Start with `rsyncronizer help`; update later with `rsyncronizer update`.

### From source

```bash
git clone https://github.com/yilmazdoga/rsyncronizer.git
cd rsyncronizer
```

The engine runs straight from the clone (`./setup.sh`, `./status.sh`). For
the CLI command, run `cli/install-cli.sh`; for the desktop app, see
[gui/README.md](gui/README.md).

The app and the CLI share one engine home, so on a machine that runs the GUI
app, update through the app; it refreshes the shared engine on launch.

## Setup

From a clone, run the wizard below; from an install, the same wizard is the
app's **New backup** button or `rsyncronizer new`.

```bash
./setup.sh
```

The wizard asks for a name, a source folder and a destination, checks that all
of it actually works, generates `backups/<name>.sh`, and optionally installs a
cron entry. Re-run it any time to change a setting; existing values come back as
defaults.

Then:

```bash
./backups/<name>.sh --dry-run    # transfers nothing, shows what would happen
./backups/<name>.sh              # the real thing
./status.sh                      # did it run? did it work?
./tests/run-tests.sh             # ~300 checks, touches no real data
```

Long first transfers should run under `tmux`.

## Two things that will bite you

**1. macOS cron cannot read `~/Documents` by default.** Until `/usr/sbin/cron` has
Full Disk Access, a scheduled job runs, reports success, and backs up almost
nothing. Grant it:

> System Settings → Privacy & Security → Full Disk Access → **+** →
> ⌘⇧G → `/usr/sbin/cron`

Do **not** try `launchctl kickstart`: System Integrity Protection refuses it
(error 150) on modern macOS. If cron is already running, log out and back in so
it picks up the grant.

```bash
./tests/cron-smoke-test.sh <backup-name>
```

These scripts detect the condition (an empty source is a hard failure, not a
silent success), but fixing it up front is better. After the first scheduled
run, check the **file count** in the log, not just the exit code.

**2. Cron does not catch up missed runs.** A job scheduled for 02:00 on a laptop
with the lid shut simply never fires, and leaves no log to tell you. `./status.sh`
reports `STALE` when the last successful run is overdue. Run it now and then.

## Backing up to a drive you plug in

A backup can target a **drive plugged into this machine** instead of another
machine over SSH. It then runs when you connect the drive, rather than on a
clock. `./setup.sh` asks which you want; pick option 2 and it detects the
mounted volume, marks it, and installs the trigger.

```bash
./setup.sh
```

- **macOS**: a launchd agent (`~/Library/LaunchAgents`). No sudo.
- **Linux**: a udev rule plus a systemd service. These live under `/etc`, so
  setup.sh writes an installer script and prints the `sudo` command rather than
  escalating on its own. Read it before you run it.

**A cooldown stops replugging from rescanning everything.** `COOLDOWN_HOURS` in
`options.txt` (default 12) skips a connect-triggered run that soon after the
last *attempt*. To force one:

```bash
rm logs/<name>/.last_attempt_epoch
```

**Two guards stop the worst failure**, which is backing up while the drive is
absent: rsync would recreate the mount-point directory on your system disk and
quietly fill it. A run proceeds only if the path is genuinely a mount point
*and* carries a `.rsync-backup-volume` marker, which lives on the drive itself.
Otherwise it exits 69 and writes nothing.

**exFAT drives** get `PRESERVE_PERMS=no` and `MODIFY_WINDOW=1` set automatically
(no Unix permissions; 2-second timestamps, without which every file looks
modified on every run). exFAT also cannot store `| < > : " ? * \` in filenames;
setup.sh counts them up front, shows which folders they cluster in, and offers
to add those to `config/<name>/exclude.txt` for you.
Note macOS actually accepts those characters on exFAT while Linux does not, so
exclude them on both machines if the drive is shared.

## Deleting at the destination

The one sanctioned exception to the never-delete rule, and it is manual by
construction:

```bash
./backups/<name>.sh --sync-deletions --dry-run   # preview only: nothing happens
./backups/<name>.sh --sync-deletions             # preview -> typed confirmation -> delete
```

A prune run first **lists every destination entry that does not exist at the
source** (the terminal shows up to 200; the full list is always in the log),
then asks you to type **`I confirm`** (or `i confirm`). Anything else aborts
with exit 75 and nothing is transferred or deleted. After you confirm, the run
**re-checks the source and recomputes the list**: if it is no longer identical
to what you confirmed (say the prompt sat open while a source volume
unmounted), it aborts with exit 75 rather than delete anything you did not see.

Details worth knowing:

- Deletion uses `--delete-after`: files are removed only **after** the transfer
  completed, so an interrupted prune deletes nothing.
- It acts on the **destination side only**. The source is never touched:
  rsync's deletion is receiver-side, and `--remove-source-files` stays banned.
- **Excluded names survive a prune.** Anything matched by `rsync-ignore.txt`
  or the per-backup `exclude.txt` (`@eaDir`, `.DS_Store`, `.rsync-partial`, …)
  is protected; only `--delete-excluded`, which stays banned, would remove it.
- It cannot be scheduled: `--sync-deletions` with `--cron` or `--on-mount` is
  refused outright, there is no config key for it, and the confirmation needs a
  real terminal on stdin *and* stdout; `echo 'I confirm' | …` does not work.
- Each scan leaves `prune-<ts>-preview.log` / `prune-<ts>-recheck.log` audit
  files in `logs/<name>/` (their own ring of 10, separate from the 30 run
  logs, so scans never crowd out real run history), and `status.sh` shows
  `[PRUNE]` plus the deleted count for the last run.
- The list is for your eyes; rsync computes the actual deletion set itself. A
  filename with a leading space or an embedded newline can render imperfectly
  in the listing, but is deleted (or kept) correctly.
- On macOS (openrsync), a directory is only removed once it is already empty:
  a folder that loses all its contents in one prune disappears on the *next*
  one (verified live; the first pass warns `not empty, cannot delete`).

## Remote servers

The app and the CLI can watch and drive backups that live on **other
machines** over SSH: `./remote.sh add workstation user@backup-server
'~/rsyncronizer'`, then `./remote.sh workstation status|run|dry|
sync-deletions <name>`. In the app, each server gets its own box under LOCAL.
All safeguards run on the owning machine: the remote engine's own preview,
typed confirmation and re-verification stream back over the connection.
Every ssh call is BatchMode-only (a broken key errors cleanly instead of
hanging; fix it with `./ssh-setup.sh user@host`, which copies your key after
asking that account's password once). If the connection drops at the prompt
the remote declines; deletions only ever run after a completed transfer.

## The CLI (no GUI needed)

`rsyncronizer` is the same engine with a terminal face (installation is
covered under *Install* above):

```bash
rsyncronizer status
rsyncronizer run <name>
rsyncronizer sync-deletions <name>
rsyncronizer ignore            # edit the global excludes in $EDITOR
rsyncronizer remote list
rsyncronizer update            # self-update from GitHub Releases (CLI installs)
```

(On a machine running the GUI app, update the app instead; it refreshes the
shared engine on launch and would revert a CLI-side update.)

`rsyncronizer help` shows the rest. It installs to the same engine home the
app uses, so the two share every backup.

## The Rsyncronizer desktop apps

**Rsyncronizer**, the standalone GUI app for macOS and Linux, lives under
[gui/](gui/) and is published on the GitHub Releases page. They are thin shells over the exact
same scripts: the wizard runs `setup.sh --answers`, the dashboard renders
`status.sh --porcelain`, and every run streams a real runner under a pty.
"Run with sync deletions" exists in the app too, with the identical
safeguards: the engine's own preview streams into the dialog and you must
type `I confirm` yourself; the app only forwards what you type, and the
engine re-verifies the list before deleting.

The app is **self-contained**: on first launch it materializes its own copy of
the engine into `~/.local/share/rsync-backup-scripts/` (both platforms; that
path is spaceless on purpose, because a space would end up inside generated crontab
lines). Its backups are managed there, independent of any clone of this repo.

**Adopting a backup you configured from a clone:** copy its `config/<name>/`
into `~/.local/share/rsync-backup-scripts/` and run the app's wizard once for
that name. Cron blocks are keyed by backup name, so the wizard *replaces* the
clone's cron entry. Do **not** also run the old clone's cron removal
afterwards, or you would strip the entry the app just installed.

Installation and the one-time macOS first-launch step are covered under
*Install* above. A locally built copy is not quarantined and just opens.

## Layout

| Path | |
| --- | --- |
| `setup.sh` | the wizard |
| `status.sh` | health report; exits non-zero if something needs attention |
| `rsync-ignore.txt` | shared exclude list, applies to every backup |
| `lib/common.sh` | the engine |
| `backups/<name>.sh` | generated runner; **gitignored**, recreated by `setup.sh` |
| `config/<name>/` | source, destination, options; **gitignored** |
| `logs/<name>/` | one log per run, newest 30 kept; **gitignored** |

`config/` and `backups/` are both gitignored: everything machine-specific is
recreated by `setup.sh` on each machine, so only the tool itself is tracked. A backup whose config is missing fails loudly and points you at
`setup.sh`; it never falls back to a default.

## Config

`config/<name>/source.txt` holds one line. Absolute, or relative to `$HOME`
(cron has no meaningful working directory):

```
Documents
```

The folder is copied **by name**, not by contents, so `~/Documents` always lands
as `<destination>/Documents/`. Trailing slashes are stripped for you; this is
the single easiest way to end up with `Documents/Documents/`, so it is not left
to chance.

`config/<name>/destination.txt`:

```
USER=alice
HOST=backup-server
DEST_PATH=backups
```

`HOST` can be an `~/.ssh/config` alias, a hostname or an IP. Leave `USER` blank
to let `~/.ssh/config` decide. Key-based auth only; the key must have **no
passphrase**, or cron can never authenticate (cron gets no ssh-agent).

`config/<name>/options.txt`, every key optional: `SSH_PORT`, `BWLIMIT`,
`TIMEOUT`, `ALLOW_EMPTY_SOURCE`, `EXTRA_FLAGS`.

**Ignore rules, nothing hidden.** `config/global-exclude.txt` IS the global
list: it is seeded once from the shipped defaults (`.DS_Store`, `@eaDir`,
`__pycache__`, …) and from then on fully replaces `rsync-ignore.txt`, so
every exclusion is visible in one editable file and deleting a line really
un-excludes it. Per-backup `config/<name>/exclude.txt` stacks on top.
Anything excluded is also protected from `--sync-deletions` at the
destination. Edit in the app ("Global Ignore Rules" / "Per-Schedule Ignore
Rules") or with `rsyncronizer ignore [name]`.

## Safety

`EXTRA_FLAGS` is not a loophole. Every flag is checked against a blacklist
immediately before rsync runs: deletion (`--delete*`, `--remove-*`, `--force`),
in-place overwrite (`--inplace`, `--append`, bare `--partial`, `-P`), and remote
command execution (`--rsync-path`, `-e`, `-M`). A blocked flag stops the run with
exit 78 before a byte moves. Config files are parsed line by line and never
sourced, so a config file cannot execute anything.

A confirmed `--sync-deletions` run does not weaken any of that: the blacklist is
never relaxed. Its `--delete-after` is appended *after* the guard has passed,
behind a second gate that verifies the run is manual, interactive, and was
confirmed by the typed phrase, so `EXTRA_FLAGS=--delete` still dies 78 even
inside a prune run.

Ownership is never preserved (`--no-o --no-g`): it only works when the receiver
runs as root, so over an ordinary SSH login it was failing silently anyway.

A backup **run** deletes nothing unless it is a confirmed `--sync-deletions` run:
otherwise its only `rm` removes this repo's own old log files, plus its own
lock directory. (`setup.sh` and the test suite do delete more, such as a
temporary crontab entry and scratch directories, but a scheduled backup never
touches either.)

Two things the never-delete rule does **not** cover, both inherent to rsync:
a destination file is unlinked if the source turns that same name into a
directory, and a destination copy is overwritten in place, so corruption at the
source propagates rather than being versioned.

## Exit codes

| | |
| --- | --- |
| 0 | success |
| 23 | partial; some files could not be read; the log names them |
| 24 | success; some source files vanished mid-run (benign) |
| 12, 255 | SSH failure; destination unreachable |
| 30, 35 | timeout; re-running resumes from `.rsync-partial` |
| 66 | refused; the source was empty or unreadable (see Full Disk Access) |
| 75 | prune declined at the prompt, or the deletion list changed after confirmation; nothing was transferred or deleted |
| 78 | misconfigured, or an unsafe flag was refused |

## Support

Rsyncronizer is completely free and will be so forever. If you find it useful,
please consider supporting me and my work:

<a href="https://buymeacoffee.com/yilmazdoga"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" height="40"></a>

The apps remind you gently: once every 10 completed backups, the desktop app
shows a small dialog and an interactive terminal run prints a note with a QR
code. If you have already supported, or simply do not want to, type
`i have supported` in the dialog (or run `rsyncronizer support --done`) and
the reminder never appears again; click Later and it returns after 10 more
backups.

## Notes

- **`--iconv` is deliberately not used.** macOS stores filenames decomposed
  (NFD) and Linux composed (NFC), and `--iconv` would normalise them. It is a
  one-way door: turning it on after the first transfer re-sends every non-ASCII
  filename under a second spelling, and since nothing is ever deleted, both live
  at the destination forever and then propagate onward. It also fails outright
  on glibc, which does not know the `utf-8-mac` charset.
- **macOS `openrsync` is fully supported.** It accepts this repo's entire flag
  set. `brew install rsync` is optional; it adds `--protect-args`, which only
  matters for destination paths containing spaces.
- **`.git/` is not excluded.** Dropping it would strip history, branches and
  stashes; for a repo with no upstream remote the backup would not be a backup.
  The cost is a slower scan phase.
