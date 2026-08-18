# shellcheck shell=bash
#
# lib/trigger-macos.sh -- install/remove a launchd agent that runs a backup when
# a drive is plugged in. Sourced by setup.sh on Darwin only.
#
# StartOnMount fires for EVERY volume mount on the machine: disk images, network
# shares, other USB sticks. That is fine and is why mount_gate is the first thing
# run_backup does -- the common case costs one stat() and writes nothing.
#
# StartInterval is a deliberate safety net, not a schedule. If the drive is left
# plugged in through a cooldown, no further mount event will ever occur, so the
# hourly poll is the only thing that will pick it up afterwards. It exits within
# milliseconds when the drive is absent.

macos_agent_label() { printf 'local.rsync-backup-scripts.%s' "$1"; }
macos_agent_plist() { printf '%s/Library/LaunchAgents/%s.plist' "$HOME" "$(macos_agent_label "$1")"; }

# macos_trigger_install NAME REPO_ROOT
macos_trigger_install() {
    _mi_name=$1
    _mi_repo=$2
    _mi_label=$(macos_agent_label "$_mi_name")
    _mi_plist=$(macos_agent_plist "$_mi_name")
    _mi_runner=$_mi_repo/backups/$_mi_name.sh
    _mi_logdir=$_mi_repo/logs/$_mi_name

    [ -x "$_mi_runner" ] || { echo "missing runner: $_mi_runner" >&2; return 1; }
    # launchd cannot spawn the job at all if it cannot open these, and the
    # failure is silent. logs/ is gitignored and disposable, so recreate it here.
    mkdir -p "$_mi_logdir" "$HOME/Library/LaunchAgents" || return 1

    cat >"$_mi_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$_mi_label</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$_mi_runner</string>
        <string>--on-mount</string>
    </array>

    <!-- Fires on EVERY volume mount. mount_gate filters, cheaply. -->
    <key>StartOnMount</key>
    <true/>

    <!-- Safety net: a drive left plugged in through the cooldown produces no
         further mount event, so nothing else would ever pick it up. -->
    <key>StartInterval</key>
    <integer>3600</integer>

    <!-- Do NOT run at load: setup.sh offers an explicit first run instead. -->
    <key>RunAtLoad</key>
    <false/>

    <key>LowPriorityIO</key>
    <true/>
    <key>Nice</key>
    <integer>5</integer>

    <key>StandardOutPath</key>
    <string>$_mi_logdir/launchd-bootstrap.log</string>
    <key>StandardErrorPath</key>
    <string>$_mi_logdir/launchd-bootstrap.log</string>
</dict>
</plist>
EOF

    plutil -lint "$_mi_plist" >/dev/null 2>&1 || {
        echo "generated plist is malformed: $_mi_plist" >&2
        return 1
    }

    # Idempotent: bootout first so a re-run replaces rather than errors with
    # "service already loaded". launchctl load/unload are deprecated on modern
    # macOS; bootstrap/bootout are the supported forms.
    launchctl bootout "gui/$(id -u)/$_mi_label" >/dev/null 2>&1
    launchctl bootstrap "gui/$(id -u)" "$_mi_plist" || {
        echo "launchctl bootstrap failed for $_mi_label" >&2
        return 1
    }
    launchctl enable "gui/$(id -u)/$_mi_label" >/dev/null 2>&1

    if launchctl print "gui/$(id -u)/$_mi_label" >/dev/null 2>&1; then
        echo "  [ok]   launchd agent installed: $_mi_label"
        return 0
    fi
    echo "installed the plist but launchctl cannot see the agent" >&2
    return 1
}

# macos_trigger_remove NAME
macos_trigger_remove() {
    _mr_label=$(macos_agent_label "$1")
    _mr_plist=$(macos_agent_plist "$1")
    launchctl bootout "gui/$(id -u)/$_mr_label" >/dev/null 2>&1
    rm -f "$_mr_plist"
    echo "  [ok]   launchd agent removed: $_mr_label"
}

# macos_trigger_status NAME -- prints a one-line state for status.sh
macos_trigger_status() {
    _ms_label=$(macos_agent_label "$1")
    if launchctl print "gui/$(id -u)/$_ms_label" >/dev/null 2>&1; then
        printf 'installed (%s)' "$_ms_label"
    else
        printf 'NOT installed'
    fi
}

# macos_volume_identity MOUNTPOINT -- best available stable identifier.
# exFAT has no real UUID, only a 32-bit volume serial, and macOS synthesises a
# UUID from it. We record whatever diskutil reports; the marker file on the
# drive is the identity check that actually runs.
macos_volume_identity() {
    _vi_mp=$1
    _vi_uuid=$(diskutil info "$_vi_mp" 2>/dev/null | awk -F': *' '/Volume UUID/{print $2; exit}')
    [ -n "$_vi_uuid" ] || _vi_uuid=$(diskutil info "$_vi_mp" 2>/dev/null | awk -F': *' '/Disk \/ Partition UUID/{print $2; exit}')
    printf '%s' "$_vi_uuid"
}
