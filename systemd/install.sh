#!/bin/bash
set -euo pipefail

# Reproducible systemd setup for catallenya, and the GATE that enforces the job
# contract.
#
# Two jobs in one script, deliberately:
#
#   1. It installs — writes the boot orchestrator, symlinks every unit, links the
#      policy drop-ins that give each job its class and family, enables timers and
#      path units.
#   2. It VALIDATES — refuses to install anything if any job breaks its contract.
#
# The second is what stops the drift this whole layout exists to fix. install.sh is
# the only sanctioned way to put a unit on this box, and the map below drives both
# the symlink and the policy, so a job that is not registered here does not get
# installed at all rather than getting installed without policy. Loud, not silent.
#
# Validation runs over EVERYTHING before ANYTHING is linked. A contract violation
# found halfway through must not leave the box half-configured.
#
# Class and family are read from each unit's own [X-Catallenya] block rather than
# repeated in a map here. One source of truth: the unit says what it is, and this
# script only decides whether to believe it.
#
# Idempotent — safe to re-run.

SYSTEMD_DIR="/etc/systemd/system"
REPO_DIR="/zpool/catallenya"

# The path units are WRITTEN against, which never moves even when REPO_DIR does.
# Every ExecStart= in this repo is an absolute /zpool/catallenya/... path, because
# systemd has no notion of a unit-relative one — so validating a tree at any other
# location has to translate them. See the ExecStart check in validate_service.
CANON_REPO="/zpool/catallenya"

# --check validates the contract and exits without touching anything. It needs no
# root, which is the point: the gate can then run in CI and be tested on its own,
# rather than only being exercised by the thing it is supposed to guard.
CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

# A CHECKER THAT CANNOT RUN MUST SAY SO, never die anonymously. `systemd-analyze
# timespan` is what turns a MaxAge= into microseconds; without it the assignment
# fails under `set -euo pipefail` and this script exits 127 having printed only
# "Validating the job contract..." — which reads as a crash in the gate rather than
# a missing package. Found the first time --check ran somewhere that was not this
# box (a bare container, 2026-08-23).
#
# Same rule ci/shellcheck.sh states for docker: a check that reports nothing because
# it never ran is the same fault as an alert dropped while the run is stamped
# healthy. GitHub's ubuntu runners ship systemd and therefore this binary; a slim
# container may not.
if ! command -v systemd-analyze >/dev/null 2>&1; then
    echo "systemd/install.sh: systemd-analyze not found — MaxAge= cannot be parsed" >&2
    echo "  It is part of the systemd package. The contract cannot be validated" >&2
    echo "  without it, and passing quietly would be worse than failing here." >&2
    exit 1
fi

# The offline suite points --check at a tree of COPIED units, so its mutation
# cases never write the real files — which are the live targets of the
# /etc/systemd/system symlinks. The old mutate-in-place suite put broken content
# into the running config for the duration of every case, and would have left it
# there had the suite died between mutate and restore (found in the 2026-08-13
# audit as NeedDaemonReload drift on five units plus mktemp-mode files).
#
# Honored ONLY under --check, deliberately: an override that could reach a real
# install would let one stray environment variable symlink the fleet at /tmp.
if (( CHECK_ONLY )) && [[ -n "${INSTALL_CHECK_REPO:-}" ]]; then
    REPO_DIR="${INSTALL_CHECK_REPO}"
fi

POLICY_DIR="${REPO_DIR}/systemd/policy"
STATE_DIR="${REPO_DIR}/systemd/state"

if [[ $EUID -ne 0 && $CHECK_ONLY -eq 0 ]]; then
    echo "Error: must run as root (sudo bash systemd/install.sh)"
    echo "       or run 'bash systemd/install.sh --check' to validate without installing"
    exit 1
fi

# =============================================================================
# What gets installed
# =============================================================================

declare -A SYMLINKS=(
    # --- Timers ---
    ["disk.timer"]="${REPO_DIR}/host/disk.timer"
    # The two pool members are IDENTICAL parts taking identical writes, so they
    # wear out on the same schedule and the mirror does not protect against it.
    # SMART is the only place that trend is visible; ZED sees a disk that has
    # already failed, scrub sees corruption, neither sees flash near its limit.
    ["smart.timer"]="${REPO_DIR}/host/smart.timer"
    # The 20 jobs had the heartbeat roll call; the 26 containers had nothing.
    # `restart: unless-stopped` means a crash-looping container never reaches a
    # failed state, and ntfy — the channel every other alert in this fleet depends
    # on — was among the seven publishing no healthcheck at all.
    ["containers.timer"]="${REPO_DIR}/host/containers.timer"
    # The one alarm that does not live on this box. It pings healthchecks.io only
    # while it can still reach our own ntfy, so an alert channel that has stopped
    # working becomes external SILENCE — the single thing this machine cannot
    # report about itself, because reporting it needs the part that is broken.
    ["deadman.timer"]="${REPO_DIR}/host/deadman.timer"
    # changedetection cannot self-report a broken watch — every fetch error just
    # sets last_error and notifies nobody. This is the only thing that looks.
    ["changedetection.health.timer"]="${REPO_DIR}/changedetection/changedetection.health.timer"
    # Not a schedule for the documents pipeline — that is event-driven. This is the
    # once-a-day look for a file type the path unit's globs cannot see.
    ["pigeonhole.backstop.timer"]="${REPO_DIR}/pigeonhole/systemd/pigeonhole.backstop.timer"
    # Calendar feeds: outside sources into their own Radicale calendars, through one
    # shared sink (radicale/feeds/feeds_sink.py). Holidays weekly — MOM publishes each
    # year as a new dataset and this finds it on its own; Filmhouse daily.
    ["holidays.sync.timer"]="${REPO_DIR}/radicale/feeds/holidays.sync.timer"
    ["filmhouse.sync.timer"]="${REPO_DIR}/radicale/feeds/filmhouse.sync.timer"
    ["immich.fix-rotations.timer"]="${REPO_DIR}/immich/immich.fix-rotations.timer"
    ["restic.backup.timer"]="${REPO_DIR}/restic/backup/restic.backup.timer"
    ["restic.check-subset.timer"]="${REPO_DIR}/restic/check/restic.check-subset.timer"
    ["restic.forget.timer"]="${REPO_DIR}/restic/forget/restic.forget.timer"
    ["restic.staleness.timer"]="${REPO_DIR}/restic/staleness/restic.staleness.timer"
    ["zpool.scrub.timer"]="${REPO_DIR}/host/zpool.scrub.timer"
    ["afterimage.sweep.timer"]="${REPO_DIR}/afterimage/systemd/afterimage.sweep.timer"
    ["pigeonhole.sweep.timer"]="${REPO_DIR}/pigeonhole/systemd/pigeonhole.sweep.timer"
    ["pigeonhole.retry.timer"]="${REPO_DIR}/pigeonhole/systemd/pigeonhole.retry.timer"
    ["ebooks.sweep.timer"]="${REPO_DIR}/ebooks/systemd/ebooks.sweep.timer"
    ["catallenya.heartbeat.timer"]="${REPO_DIR}/systemd/catallenya.heartbeat.timer"
    # liquidroom polls rather than watching, and that is forced: a request is an
    # empty FOLDER now and no .path verb can express emptiness. It REPLACED
    # liquidroom.triage.path on 2026-08-28 — see liquidroom/systemd/liquidroom.triage.timer.
    ["liquidroom.triage.timer"]="${REPO_DIR}/liquidroom/systemd/liquidroom.triage.timer"
    # Grayjay's playlist backup arrives over Syncthing every couple of days; once a day
    # the new videos in two playlists are handed to ArchiveBox.
    ["grayjay.archive.timer"]="${REPO_DIR}/grayjay/systemd/grayjay.archive.timer"

    # --- Paths (event-triggered, not scheduled) ---
    ["afterimage.triage.path"]="${REPO_DIR}/afterimage/systemd/afterimage.triage.path"
    # documents is two path units and no timer of its own: one watches the folder
    # root for a dropped document, the other watches for an approval marker the
    # container wrote. A document is proposed when it arrives and filed when you
    # tap, not overnight.
    ["pigeonhole.triage.path"]="${REPO_DIR}/pigeonhole/systemd/pigeonhole.triage.path"
    ["pigeonhole.apply.path"]="${REPO_DIR}/pigeonhole/systemd/pigeonhole.apply.path"
    # ebooks is pigeonhole's shape without the model: one path unit watches the inbox
    # for a dropped book, the other watches for an approval marker the container wrote.
    ["ebooks.triage.path"]="${REPO_DIR}/ebooks/systemd/ebooks.triage.path"
    ["ebooks.apply.path"]="${REPO_DIR}/ebooks/systemd/ebooks.apply.path"

    # --- Services ---
    ["disk.service"]="${REPO_DIR}/host/disk.service"
    ["smart.service"]="${REPO_DIR}/host/smart.service"
    ["containers.service"]="${REPO_DIR}/host/containers.service"
    ["deadman.service"]="${REPO_DIR}/host/deadman.service"
    ["changedetection.health.service"]="${REPO_DIR}/changedetection/changedetection.health.service"
    ["holidays.sync.service"]="${REPO_DIR}/radicale/feeds/holidays.sync.service"
    ["filmhouse.sync.service"]="${REPO_DIR}/radicale/feeds/filmhouse.sync.service"
    ["pigeonhole.triage.service"]="${REPO_DIR}/pigeonhole/systemd/pigeonhole.triage.service"
    ["pigeonhole.apply.service"]="${REPO_DIR}/pigeonhole/systemd/pigeonhole.apply.service"
    ["pigeonhole.sweep.service"]="${REPO_DIR}/pigeonhole/systemd/pigeonhole.sweep.service"
    ["pigeonhole.retry.service"]="${REPO_DIR}/pigeonhole/systemd/pigeonhole.retry.service"
    ["ebooks.triage.service"]="${REPO_DIR}/ebooks/systemd/ebooks.triage.service"
    ["ebooks.apply.service"]="${REPO_DIR}/ebooks/systemd/ebooks.apply.service"
    ["ebooks.sweep.service"]="${REPO_DIR}/ebooks/systemd/ebooks.sweep.service"
    ["immich.fix-rotations.service"]="${REPO_DIR}/immich/immich.fix-rotations.service"
    ["restic.backup.service"]="${REPO_DIR}/restic/backup/restic.backup.service"
    ["restic.check@.service"]="${REPO_DIR}/restic/check/restic.check@.service"
    ["restic.forget.service"]="${REPO_DIR}/restic/forget/restic.forget.service"
    ["restic.staleness.service"]="${REPO_DIR}/restic/staleness/restic.staleness.service"
    ["system-ntfy@.service"]="${REPO_DIR}/ntfy/system-ntfy@.service"
    ["zpool.scrub.service"]="${REPO_DIR}/host/zpool.scrub.service"
    ["afterimage.triage.service"]="${REPO_DIR}/afterimage/systemd/afterimage.triage.service"
    ["afterimage.sweep.service"]="${REPO_DIR}/afterimage/systemd/afterimage.sweep.service"
    ["liquidroom.triage.service"]="${REPO_DIR}/liquidroom/systemd/liquidroom.triage.service"
    ["grayjay.archive.service"]="${REPO_DIR}/grayjay/systemd/grayjay.archive.service"
    ["catallenya.heartbeat.service"]="${REPO_DIR}/systemd/catallenya.heartbeat.service"
)

# Units that are NOT jobs and therefore inherit no job policy.
#
# system-ntfy@ is the courier: every OnFailure= in the fleet points at it. Give it
# the base policy and a failed alert would start a courier to complain about the
# courier, which fails, which starts another. It is plumbing, and this is a
# category with a reason rather than a bare exception — future plumbing has a home.
declare -A PLUMBING=(
    ["system-ntfy@.service"]=1
)

# Per-instance stickers for template units.
#
# systemd ignores the [X-Catallenya] section entirely, which means %i is never
# expanded inside it — a template physically cannot carry per-instance metadata.
# Instance drop-in directories are searched before the template's own, so these win.
#
# There is only one instance since the yearly restic.check@data was retired
# (2026-08-22), which does not make this map redundant: check@subset still needs a
# MaxAge and a Freshness, and the template still cannot express either. check@data
# remains runnable BY HAND and deliberately has no sticker — an on-demand job has
# no cadence to be stale against, so giving it one would page about a run nobody
# scheduled.
declare -A INSTANCE_DROPINS=(
    ["restic.check@subset.service"]="${REPO_DIR}/restic/check/instance-subset.conf"
)

# =============================================================================
# The contract
# =============================================================================

ERRORS=()
err() { ERRORS+=("$1"); }
declare -A INTAKE_SEEN=()

# Read a key from a file's [X-Catallenya] section. LAST match wins.
#
# This MUST stay byte-identical in behaviour to sticker() in systemd/heartbeat.sh.
# It previously took the FIRST match while the watchdog took the last, so a unit
# with two MaxAge= lines showed the gate one value and the watchdog another — two
# jobs dead for a year while both layers reported them healthy.
sticker() {
    awk -v k="$2" '
        /^\[/  { inside = ($0 == "[X-Catallenya]"); next }
        inside && index($0, k "=") == 1 { v = substr($0, length(k) + 2) }
        END { if (v != "") print v }
    ' "$1"
}

# Section-aware, whitespace-normalising, LAST-WINS reader — the same semantics
# systemd uses. The previous version was `grep -qE "^KEY="`, which is section-blind
# and anchored: it accepted CapabilityBoundingSet= hidden in [Unit] (where systemd
# ignores it), missed `··ConditionPathExists=` behind one space, read the FIRST
# User= where systemd takes the last, and was fooled by a `\`-continuation
# swallowing the following line. Every one of those got a non-conformant unit past
# the gate.
directive() {                       # directive <file> <section> <key>
    awk -v want="$2" -v k="$3" '
        # Join continuation lines the way systemd does, so a swallowed directive
        # is invisible here exactly as it is to systemd.
        { line = line $0
          if (line ~ /\\$/) { sub(/\\$/, "", line); next } }
        {
          s = line; line = ""
          gsub(/^[ \t]+|[ \t]+$/, "", s)
          if (s ~ /^\[.*\]$/) { sec = substr(s, 2, length(s) - 2); next }
          if (s ~ /^[#;]/ || s == "") next
          if (sec != want) next
          split(s, kv, "=")
          key = kv[1]; gsub(/[ \t]/, "", key)
          if (key != k) next
          v = substr(s, index(s, "=") + 1)
          gsub(/^[ \t]+|[ \t]+$/, "", v)
          val = v; seen = 1
        }
        END { if (seen) print val }
    ' "$1"
}
# Requirement checks are SECTION-AWARE and nothing else: a directive in the wrong
# section is one systemd ignores, so "present somewhere in the file" must never
# satisfy "required here". The old section-blind fallback let TimeoutStartSec=2h
# in [Unit] pass while the job actually ran at the oneshot default of infinity,
# and let User=carrein in [Unit] pass while systemd ran the unit as ROOT — with
# the unbounded-root check skipped, because the section-aware reader correctly
# saw no [Service] User at all.
has_key() {                         # has_key <file> <key> [section]
    [[ -n "$(directive "$1" "${3:-Service}" "$2")" ]]
}
# Prohibition checks stay deliberately BLUNT: a forbidden directive is refused
# wherever it appears. Even where systemd would ignore it, the line reads as
# configuration and is a lie — refusing a misplaced RuntimeMaxSec= is
# conservative, never wrong.
has_key_anywhere() {                # has_key_anywhere <file> <key> [section]
    has_key "$@" || \
    grep -qE "^[[:space:]]*${2}[[:space:]]*=" "$1"
}

# Directives each layer SETS. A unit repeating one of these is not merely
# redundant — drop-ins outrank the unit file, so the unit's value is silently
# discarded. A line that does nothing is worse than no line: it reads as
# configuration and is a lie. These are scalars only; list-valued directives
# (Requires=, After=, Environment=, ReadWritePaths=) accumulate and may legitimately
# appear in both places.
BASE_SETS="Type StandardOutput StandardError SyslogIdentifier NoNewPrivileges PrivateTmp RestrictRealtime LockPersonality SystemCallArchitectures ProtectClock ProtectKernelModules UMask"
MONITOR_SETS="TimeoutStartSec ProtectSystem ProtectHome ProtectKernelTunables ProtectControlGroups RestrictSUIDSGID"
INTAKE_SETS="ProtectSystem ProtectHome ProtectKernelTunables ProtectControlGroups RestrictSUIDSGID"
ADHOC_SETS="StartLimitIntervalSec StartLimitBurst"
TIMER_SETS="Persistent"

check_not_reset() {
    local file="$1" unit="$2" layer="$3"; shift 3
    # "$@" — callers pass the key list already split (check_not_reset … $BASE_SETS),
    # so re-splitting here buys nothing and shellcheck rightly calls SC2068 an
    # error rather than a warning. Behaviour is identical; CI is not.
    for key in "$@"; do
        has_key_anywhere "$file" "$key" && \
            err "${unit}: sets ${key}=, which the ${layer} policy already sets — the unit's value is silently discarded. Remove the line."
    done
    return 0
}

# The intake code contract lives in its own file so the suite can call it directly
# against a fixture; install.sh runs an installer when sourced.
# Sourced from THIS script's own directory, deliberately, not from $REPO_DIR:
# --check points REPO_DIR at a throwaway tree of units to validate, and the
# installer's own code does not live there. Sourcing it via REPO_DIR made every gate
# test fail with "No such file or directory" the moment the suite ran.
# shellcheck source=/zpool/catallenya/systemd/contract.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/contract.sh"


validate_service() {
    local unit="$1" file="$2"

    [[ -n "${PLUMBING[$unit]:-}" ]] && return 0

    local class family maxage freshness
    class=$(sticker "$file" Class)
    family=$(sticker "$file" Family)
    maxage=$(sticker "$file" MaxAge)
    freshness=$(sticker "$file" Freshness)

    case "$class" in
        scheduled|monitor|adhoc) ;;
        "") err "${unit}: no [X-Catallenya] Class=. Every job declares one, or is listed as PLUMBING."; return 0 ;;
        *)  err "${unit}: unknown Class=${class} (expected scheduled, monitor or adhoc)."; return 0 ;;
    esac

    case "$family" in
        ""|intake|restic) ;;
        *) err "${unit}: unknown Family=${family} (expected intake, restic, or none)." ;;
    esac

    # --- base contract ---
    has_key "$file" "User" || \
        err "${unit}: no explicit User=. The base policy deliberately does not set one: 13 of 15 units run as carrein, but zpool.scrub and catallenya need root, and a hoisted User= would silently demote them."
    local user; user=$(directive "$file" Service User)
    if [[ "$user" == "root" || "$user" == "0" ]]; then
        # Must be in [Service]; systemd ignores it anywhere else, so a bound
        # declared in [Unit] or inside the sticker is no bound at all.
        # A bound, OR an explicit acknowledgement in the sticker. The escape hatch is
        # deliberate and must be WRITTEN DOWN: silently omitting the directive would
        # look identical to forgetting it.
        if [[ -z "$(directive "$file" Service CapabilityBoundingSet)" ]] && \
           [[ "$(sticker "$file" UnboundedRoot)" != "acknowledged" ]]; then
            err "${unit}: runs as root without a CapabilityBoundingSet= in [Service]. Root is allowed; unbounded root is not — bound it, or declare 'UnboundedRoot=acknowledged' in [X-Catallenya] with a comment saying why."
        fi
    fi
    grep -qE '^[[:space:]]*Condition[A-Za-z]*[[:space:]]*=' "$file" && \
        err "${unit}: uses a Condition*= directive. A failed Condition is a SKIP, not a failure — no exit code, no OnFailure=, no journal error. Use Requires= so a missing precondition fails loudly. This is how sanoid stopped snapshotting silently."
    # CANCELLING OnFailure= MUST BE DECLARED, never merely done.
    #
    # An empty assignment resets the list systemd would otherwise APPEND to, so this
    # one line switches off a job's failure alerting entirely — the same silent-failure
    # class the Condition*= rule above exists to prevent, arrived at from the other
    # direction. It is legitimate for a job that already sends its own message, and
    # catallenya does exactly that; what is not legitimate is doing it quietly, where a
    # later reader cannot tell a deliberate exemption from a mistake.
    #
    # Same shape as UnboundedRoot=acknowledged: the escape hatch is real and must be
    # WRITTEN DOWN.
    #
    # NOTHING USES IT TODAY, and the gate keeps it that way — the same reason the
    # RuntimeMaxSec= and `ExecStart=-` rules above exist for directives no unit sets.
    # catallenya briefly cancelled its OnFailure= to stop a bad boot sending two
    # messages; that was reverted deliberately (see ntfy/MESSAGES.md § 8) because the
    # second message is the only evidence the OnFailure= path still works for that
    # unit, and because a script that dies BEFORE it can notify is then covered in
    # seconds rather than by the watchdog hours later.
    if grep -qE '^[[:space:]]*OnFailure[[:space:]]*=[[:space:]]*$' "$file" && \
       [[ "$(sticker "$file" SelfAlerting)" != "acknowledged" ]]; then
        err "${unit}: cancels its inherited OnFailure= with an empty assignment, which switches off failure alerting for this job. That is allowed only for a job that sends its own notification — declare 'SelfAlerting=acknowledged' in [X-Catallenya] with a comment saying what does alert, and what still catches the failure if that message never arrives."
    fi
    has_key_anywhere "$file" "RuntimeMaxSec" && \
        err "${unit}: sets RuntimeMaxSec=, which systemd IGNORES on Type=oneshot while still reporting it in \`systemctl show\`. Use TimeoutStartSec=."
    # Both would write a FALSE HEALTHY completion stamp: ExecStartPost= runs when
    # systemd considers ExecStart successful, and each of these makes a failure
    # look like success. Neither is used anywhere today; the gate keeps it that way.
    grep -qE '^[[:space:]]*ExecStart[[:space:]]*=[[:space:]]*-' "$file" && \
        err "${unit}: ExecStart= is prefixed with '-', so a failing command counts as success and the completion stamp would be written anyway. The watchdog would report this job healthy forever."
    has_key_anywhere "$file" "SuccessExitStatus" && \
        err "${unit}: sets SuccessExitStatus=, which makes a non-zero exit count as success — the completion stamp would be written for a failed run."

    # The ExecStart binary must exist and be EXECUTABLE. systemd answers a missing
    # +x bit with 203/EXEC and nothing else — no hint about the mode, and the job
    # then fails on every trigger. For a .path-driven job that means the watcher
    # re-fires, the service fails again, and OnFailure= sends an alert per spin
    # until the class start limit stops it: liquidroom.triage did exactly this on
    # its first live deploy and cost five notifications. Files written by tooling
    # default to 0644, so this is easy to reintroduce and invisible in review.
    #
    # AN ExecStart= IS ABSOLUTE AND DOES NOT MOVE WITH THE TREE. INSTALL_CHECK_REPO
    # relocates where units are FOUND; the /zpool/catallenya/... inside them is a
    # literal. Checking it as written is right on this box and wrong everywhere
    # else — on a CI runner /zpool does not exist, so all 19 service units reported
    # a missing script and the job failed on a perfectly good tree. (Found the
    # first time this check ran in CI, 2026-08-23, which is the job earning its
    # place on the day it was added.)
    #
    # So a relocated tree translates the repo prefix and checks the copy actually
    # being validated. Paths OUTSIDE the repo are skipped there and only there:
    # zpool.scrub.service runs /usr/sbin/zpool, which a runner has no reason to
    # have, and demanding it would mean CI could only pass on a machine that is
    # already a ZFS host. On the real box nothing is skipped — a missing zpool
    # binary is exactly the kind of thing this check should still catch.
    # A RELOCATED TREE MAY HOLD EITHER, so accept either. Two callers relocate and
    # they are not the same shape: a CI runner has the whole repo but no /zpool,
    # while systemd/tests/run.sh copies UNITS ONLY into a scratch dir and leaves the
    # scripts where they are. Translating unconditionally broke the suite (18 units
    # reporting a script that is simply not in the check tree, and the
    # non-executable case reading "does not exist" instead); checking only the
    # literal broke CI. So: prefer the copy in the tree being validated, fall back
    # to the canonical path, and only complain when NEITHER is there.
    local execbin execpath execalt
    execbin="$(grep -m1 -oP '^\s*ExecStart\s*=\s*\K[^ ]+' "$file" 2>/dev/null)"
    execpath="$execbin"
    if [[ -n "$execbin" && "$execbin" == /* && "$REPO_DIR" != "$CANON_REPO" ]]; then
        if [[ "$execbin" == "${CANON_REPO}/"* ]]; then
            execalt="${REPO_DIR}/${execbin#"${CANON_REPO}/"}"
            [[ -e "$execalt" ]] && execpath="$execalt"
        else
            execpath=""   # a system binary, not this tree's to vouch for
        fi
    fi
    if [[ -n "$execpath" && "$execpath" == /* ]]; then
        [[ -e "$execpath" ]] || \
            err "${unit}: ExecStart= points at ${execbin}, which does not exist."
        [[ ! -e "$execpath" || -x "$execpath" ]] || \
            err "${unit}: ExecStart= target ${execbin} is not executable (mode $(stat -c %a "$execpath" 2>/dev/null)). systemd fails it with 203/EXEC, which names no cause. Run: chmod 755 ${execbin}"
    fi

    check_not_reset "$file" "$unit" base $BASE_SETS

    # --- class contract ---
    case "$class" in
        scheduled)
            has_key "$file" "TimeoutStartSec" || \
                err "${unit}: Class=scheduled requires an explicit finite TimeoutStartSec=. Three of these ran at \`infinity\`, where a hung run holds a repository lock forever and is never collected as stale."
            # A template carries its MaxAge/Freshness in instance drop-ins instead.
            if [[ "$unit" != *@.service ]]; then
                [[ -n "$maxage" ]]    || err "${unit}: Class=scheduled requires MaxAge=."
                [[ -n "$freshness" ]] || err "${unit}: Class=scheduled requires Freshness=."
            fi
            ;;
        monitor)
            [[ -n "$maxage" ]] || err "${unit}: Class=monitor requires MaxAge=."
            [[ -z "$freshness" ]] || \
                err "${unit}: Class=monitor must not declare Freshness= — a monitor produces nothing but its own completion stamp, so it is implied."
            has_key_anywhere "$file" "TimeoutStartSec" && \
                err "${unit}: Class=monitor must not set TimeoutStartSec= — the class sets 10min and would discard this."
            # Not stylistic. An empty OnSuccess= in a drop-in does NOT reset a
            # [Unit] dependency list (measured: the declared handler still runs),
            # so the monitor class physically cannot strip one. Refusing here is
            # the only enforcement available.
            has_key_anywhere "$file" "OnSuccess" Unit && \
                err "${unit}: Class=monitor must not declare OnSuccess= — silence is the healthy state, and a drop-in cannot reset a [Unit] dependency list, so this is the only place it can be stopped."
            check_not_reset "$file" "$unit" monitor $MONITOR_SETS
            ;;
        adhoc)
            has_key "$file" "TimeoutStartSec" || \
                err "${unit}: Class=adhoc requires an explicit TimeoutStartSec=."
            [[ -n "$freshness" ]] || \
                err "${unit}: Class=adhoc requires Freshness= naming the .path unit to check, or the literal 'boot'."
            [[ -z "$maxage" ]] || \
                err "${unit}: Class=adhoc must not declare MaxAge= — an event-driven job has no cadence to be stale against."
            # An armed watcher does not prove anything can reach it. Required, not
            # optional, so a future event job cannot quietly inherit the blind spot.
            local producer; producer=$(sticker "$file" Producer)
            if [[ "$freshness" == unit:* ]]; then
                [[ -n "$producer" ]] || \
                    err "${unit}: Class=adhoc with a .path watcher must declare Producer= naming what feeds it — a .path unit reports active even when nothing can ever arrive."
                [[ -z "$producer" || "$producer" == container:* ]] || \
                    err "${unit}: Producer=${producer} is not a recognised form (expected container:<name>)."
            fi
            check_not_reset "$file" "$unit" adhoc $ADHOC_SETS
            ;;
    esac

    # --- family contract ---
    if [[ "$family" == "intake" ]]; then
        check_not_reset "$file" "$unit" intake $INTAKE_SETS
        # The pipeline directory is two levels up from scripts/<job>.sh. Checked once
        # per pipeline rather than once per unit, since every unit in a family points
        # at the same tree.
        local exec_path pipe_dir
        exec_path="$(sed -n 's/^ExecStart=\([^ ]*\).*/\1/p' "$file" | head -1)"
        pipe_dir="$(dirname "$(dirname "$exec_path")")"
        if [[ -d "$pipe_dir" && -z "${INTAKE_SEEN[$pipe_dir]:-}" ]]; then
            INTAKE_SEEN[$pipe_dir]=1
            intake_contract "$pipe_dir" "$(basename "$pipe_dir")"
        fi
    fi

    # MaxAge=infinity parses to 18446744073709551615us, which the watchdog renders
    # as 1.84467e+13 and bash then refuses to compare — the check silently passes.
    # A MaxAge that disables its own check is worse than none.
    if [[ -n "$maxage" ]]; then
        local us; us=$(systemd-analyze timespan "$maxage" 2>/dev/null | awk 'NR==2 {print $NF}')
        if [[ ! "$us" =~ ^[0-9]+$ ]] || (( ${#us} > 15 )); then
            err "${unit}: MaxAge=${maxage} does not parse to a usable finite timespan (infinity and anything beyond ~31 years silently disable the check)."
        fi
    fi

    # --- freshness vocabulary ---
    if [[ -n "$freshness" ]]; then
        case "$freshness" in
            stamp:/*|unit:*|zfs-scrub:*|zfs-snapshot:*|boot) ;;
            *) err "${unit}: Freshness=${freshness} is not a recognised form. Use stamp:<abs-path>, unit:<unit>, zfs-scrub:<pool>, zfs-snapshot:<dataset>, or boot." ;;
        esac
    fi
    return 0
}

validate_timer() {
    local unit="$1" file="$2"
    has_key "$file" "OnCalendar" Timer || err "${unit}: no OnCalendar= in [Timer]."
    has_key "$file" "RandomizedDelaySec" Timer || \
        err "${unit}: no RandomizedDelaySec= in [Timer]. Several of these contend for the same repository lock, and an un-jittered timer lands on the hour alongside every other job scheduled on the hour."
    grep -qE '^\[Install\]' "$file" && \
        err "${unit}: declares its own [Install] section, which 10-base-timer.conf already provides."
    check_not_reset "$file" "$unit" base-timer $TIMER_SETS
    return 0
}

# .path units went entirely unvalidated until 2026-08-19 — the dispatch matched
# only *.service and *.timer, so a .path full of garbage passed the gate clean.
# The rules are few because a .path is small, but each one is a silence:
validate_path() {
    local unit="$1" file="$2"
    # The same trap the service rule guards: a failed Condition is a SKIP, not a
    # failure — no exit code, no OnFailure=, no journal error. On a watcher that
    # means the pipeline looks installed while nothing ever fires.
    grep -qE '^[[:space:]]*Condition[A-Za-z]*[[:space:]]*=' "$file" && \
        err "${unit}: uses a Condition*= directive. A failed Condition is a SKIP, not a failure — no exit code, no OnFailure=, no journal error — so the watcher would silently never arm. Use Requires= so a missing precondition fails loudly."
    # Unlike timers, path units inherit no [Install] from a policy drop-in, and
    # install.sh enables them with `systemctl enable --now`: without a WantedBy=
    # the enable fails, the watcher runs until the next reboot and never again.
    grep -qE '^\[Install\]' "$file" || \
        err "${unit}: has no [Install] section. Path units are enabled with \`systemctl enable --now\`, which needs a WantedBy= — without one the watcher arms this boot and is gone on the next."
    # A .path that watches nothing loads cleanly and does nothing forever.
    local key watched=0
    for key in PathExists PathExistsGlob PathChanged PathModified DirectoryNotEmpty; do
        [[ -n "$(directive "$file" Path "$key")" ]] && { watched=1; break; }
    done
    (( watched )) || \
        err "${unit}: watches nothing — no PathExists=, PathExistsGlob=, PathChanged=, PathModified= or DirectoryNotEmpty= in [Path]. An armed watcher with no watched path never fires, and the watchdog reads 'active' as healthy."
    return 0
}

# =============================================================================
# Validate everything, before touching anything
# =============================================================================

echo "Validating the job contract..."

for f in "${POLICY_DIR}"/10-base.conf "${POLICY_DIR}"/10-base-timer.conf \
         "${POLICY_DIR}"/20-scheduled.conf "${POLICY_DIR}"/20-monitor.conf \
         "${POLICY_DIR}"/20-adhoc.conf "${POLICY_DIR}"/30-intake.conf \
         "${POLICY_DIR}"/30-restic.conf; do
    [[ -f "$f" ]] || err "policy file missing: ${f}"
done

# Which services are triggered by some timer. Not derivable from the name alone:
# restic.check-subset.timer fires restic.check@subset.service, and
# pigeonhole.backstop.timer fires pigeonhole.triage.service.
declare -A TIMER_TARGETS=()
for unit in "${!SYMLINKS[@]}"; do
    [[ "$unit" == *.timer ]] || continue
    src="${SYMLINKS[$unit]}"
    [[ -f "$src" ]] || continue
    target=$(grep -m1 '^Unit=' "$src" | cut -d= -f2- || true)
    [[ -n "$target" ]] || target="${unit%.timer}.service"
    TIMER_TARGETS["$target"]=1
done

for unit in "${!SYMLINKS[@]}"; do
    src="${SYMLINKS[$unit]}"
    if [[ ! -f "$src" ]]; then
        err "${unit}: source file does not exist: ${src}"
        continue
    fi
    case "$unit" in
        *.service) validate_service "$unit" "$src" ;;
        *.timer)   validate_timer   "$unit" "$src" ;;
        *.path)    validate_path    "$unit" "$src" ;;
    esac
done

# CI YAML can emit a notification too, and until 2026-08-23 nothing checked it —
# contract.sh only ever read *.sh, so notify-failure kept sending `Priority: high`
# and a tag for three days after both were removed from notify() repo-wide. Called
# once rather than per-unit: it is a property of the repo, not of any job.
workflow_contract "${REPO_DIR}/.github/workflows"

# The SYMLINKS map is hand-maintained, and a unit that never makes it in is the
# quietest failure this layout allows: it validates nothing, installs nothing,
# and declares a Class the watchdog will never read — proven with a rogue unit
# carrying six violations that sailed past as "OK 35 units". So the tree is
# cross-checked against the map: every committed unit file must be registered.
# (The reverse — a map key whose file is gone — is already a refusal above.)
#
# git is authoritative when available; when it is not — --check must work under
# an INSTALL_CHECK_REPO scratch tree, and root running the real install may be
# refused by git's ownership check — fall back to the same directory list the
# offline suite builds its check tree from. A unit committed to a brand-new
# directory is what the git arm exists to catch; the fallback cannot see it,
# which is exactly the blindness that broke 23 suite cases on 2026-08-15.
tracked_units() {
    if git -C "${REPO_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git -C "${REPO_DIR}" ls-files -- '*.service' '*.timer' '*.path'
    else
        local d
        for d in systemd restic host changedetection ntfy afterimage/systemd \
                 pigeonhole/systemd ebooks/systemd liquidroom/systemd immich \
                 radicale/feeds grayjay/systemd; do
            [[ -d "${REPO_DIR}/${d}" ]] || continue
            ( cd "${REPO_DIR}" && find "$d" \
                \( -name '*.service' -o -name '*.timer' -o -name '*.path' \) )
        done
    fi
}
declare -A REGISTERED=()
for unit in "${!SYMLINKS[@]}"; do REGISTERED["${SYMLINKS[$unit]}"]=1; done
while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    [[ -n "${REGISTERED["${REPO_DIR}/${rel}"]:-}" ]] || \
        err "${rel}: unit file is in the tree but not in install.sh's SYMLINKS map — it is validated by nothing, installed by nothing, and invisible to the watchdog. Register it, or remove the file."
done < <(tracked_units)

# A scheduled job with no timer never runs. Checked separately because it needs
# the whole map, not one unit.
for unit in "${!SYMLINKS[@]}"; do
    [[ "$unit" == *.service ]] || continue
    [[ -n "${PLUMBING[$unit]:-}" ]] && continue
    src="${SYMLINKS[$unit]}"
    [[ -f "$src" ]] || continue
    [[ "$(sticker "$src" Class)" == "scheduled" ]] || continue
    if [[ "$unit" == *@.service ]]; then
        # Template: at least one instance must be triggered by a timer.
        found=0
        for t in "${!TIMER_TARGETS[@]}"; do
            [[ "$t" == "${unit%@.service}@"*".service" ]] && found=1
        done
        (( found )) || err "${unit}: Class=scheduled but no timer fires any instance of it."
    else
        [[ -n "${TIMER_TARGETS[$unit]:-}" ]] || \
            err "${unit}: Class=scheduled but no timer fires it — a scheduled job with no timer never runs."
    fi
done

# Instance stickers must exist and carry what the template cannot.
for inst in "${!INSTANCE_DROPINS[@]}"; do
    f="${INSTANCE_DROPINS[$inst]}"
    if [[ ! -f "$f" ]]; then
        err "${inst}: instance sticker missing: ${f}"
        continue
    fi
    [[ -n "$(sticker "$f" MaxAge)" ]]    || err "${inst}: instance sticker has no MaxAge=."
    [[ -n "$(sticker "$f" Freshness)" ]] || err "${inst}: instance sticker has no Freshness=."
done

if (( ${#ERRORS[@]} )); then
    echo
    echo "REFUSING TO INSTALL — ${#ERRORS[@]} contract violation(s):"
    printf '  - %s\n' "${ERRORS[@]}"
    echo
    echo "Nothing was changed. ${SYSTEMD_DIR} is untouched."
    exit 1
fi
echo "  OK  ${#SYMLINKS[@]} units satisfy the contract"

if (( CHECK_ONLY )); then
    echo "--check: contract satisfied, nothing installed."
    exit 0
fi

# =============================================================================
# Install
# =============================================================================

# The boot orchestrator is the one unit that cannot be a symlink: it runs before
# ZFS is mounted, so a link into /zpool would not resolve when PID 1 builds the
# boot transaction.
echo "Writing catallenya.service..."
cat > "${SYSTEMD_DIR}/catallenya.service" <<'EOF'
# Class: adhoc  (see systemd/policy/20-adhoc.conf) — boot is an event.
#
# Written by systemd/install.sh rather than symlinked: this unit runs before ZFS is
# mounted, so a link into /zpool would not resolve when PID 1 builds the boot
# transaction. Edit it in install.sh, never here.
[Unit]
Description=Catallenya Boot Orchestrator
After=zfs-mount.service docker.service network-online.target
Requires=zfs-mount.service docker.service
Wants=network-online.target

# Was ConditionPathIsMountPoint=/zpool. A failed Condition is a SKIP, not a
# failure: no exit code, no OnFailure=, no journal error. A boot where the pool did
# not mount produced no timers, no containers and NO NOTIFICATION, while
# `systemctl status` reported the unit as merely skipped. Requires=zfs-mount.service
# above already covers the same precondition and fails loudly.

[Service]
Type=oneshot
User=root
# NO CapabilityBoundingSet, and that is a decision rather than an omission.
#
# A bound of CAP_SYS_ADMIN CAP_SETUID CAP_SETGID CAP_DAC_OVERRIDE CAP_CHOWN was
# tried on 2026-08-13 and BROKE THIS UNIT: `runuser: cannot set user id: Operation
# not permitted`, so docker compose never ran. Verified NoNewPrivileges is not the
# cause — runuser succeeds under NNP alone.
#
# This unit orchestrates arbitrary other units AND drops to another user via PAM,
# which pulls in capabilities beyond the obvious setuid/setgid pair. Narrowing it
# by trial and error, on the one job whose failure means nothing starts at boot,
# trades a real risk for a theoretical gain. zpool.scrub keeps its bound because
# its needs are exactly one capability and provable.
#
# The gate requires this to be acknowledged in the sticker rather than merely
# absent, so it can never be confused with someone forgetting.
RemainAfterExit=yes
ExecStart=/zpool/catallenya/host/catallenya.sh

# Was 300s, which sat around `docker compose up -d`. A cold image pull on a slow
# link exceeds five minutes, and the ntfy push is step 5 — AFTER compose — so a
# slow boot was killed before it could report anything.
TimeoutStartSec=20min

[Install]
WantedBy=multi-user.target

[X-Catallenya]
Class=adhoc
Freshness=boot
UnboundedRoot=acknowledged
EOF

echo "Creating unit symlinks..."
for unit in "${!SYMLINKS[@]}"; do
    target="${SYMLINKS[$unit]}"
    link="${SYSTEMD_DIR}/${unit}"
    if [[ -L "$link" && "$(readlink "$link")" == "$target" ]]; then
        echo "  OK  ${unit}"
    else
        ln -sf "$target" "$link"
        echo "  NEW ${unit}"
    fi
done

# Link each job's policy. This is what makes a job a job: base always, then its
# class, then its family if it has one. Filenames sort so that later layers win.
link_policy() {
    local unit="$1" src="$2" dir="${SYSTEMD_DIR}/${1}.d"
    local class family
    class=$(sticker "$src" Class)
    family=$(sticker "$src" Family)
    mkdir -p "$dir"
    ln -sf "${POLICY_DIR}/10-base.conf" "${dir}/10-base.conf"
    ln -sf "${POLICY_DIR}/20-${class}.conf" "${dir}/20-${class}.conf"
    if [[ -n "$family" ]]; then
        ln -sf "${POLICY_DIR}/30-${family}.conf" "${dir}/30-${family}.conf"
    fi
    # Remove a stale layer left by a class or family change.
    for f in "${dir}"/20-*.conf; do
        [[ -e "$f" ]] || continue
        [[ "$(basename "$f")" == "20-${class}.conf" ]] || { rm -f "$f"; echo "      dropped stale $(basename "$f")"; }
    done
    for f in "${dir}"/30-*.conf; do
        [[ -e "$f" ]] || continue
        [[ -n "$family" && "$(basename "$f")" == "30-${family}.conf" ]] || { rm -f "$f"; echo "      dropped stale $(basename "$f")"; }
    done
    echo "  POLICY ${unit}: base + ${class}${family:+ + ${family}}"
}

echo "Linking policy drop-ins..."
for unit in "${!SYMLINKS[@]}"; do
    [[ "$unit" == *.service ]] || continue
    [[ -n "${PLUMBING[$unit]:-}" ]] && { echo "  SKIP ${unit} (plumbing — inherits no job policy)"; continue; }
    link_policy "$unit" "${SYMLINKS[$unit]}"
done
# NOT link_policy: that creates symlinks into /zpool, and this is the one unit
# that must load before ZFS is mounted. A dangling drop-in symlink is SILENTLY
# ignored — LoadState stays `loaded`, the unit runs, and it simply has no policy;
# the only tell is UnitFileState=bad, which nothing reads. The unit would then
# boot without its OnFailure=, so a failure before catallenya.sh's own
# daemon-reload — /zpool unmounted, the script missing, zfs-mount failing —
# would notify nobody. That is precisely the silence this refactor removed when it
# dropped ConditionPathIsMountPoint=. Copies, not links.
mkdir -p "${SYSTEMD_DIR}/catallenya.service.d"
cp -f "${POLICY_DIR}/10-base.conf"  "${SYSTEMD_DIR}/catallenya.service.d/10-base.conf"
cp -f "${POLICY_DIR}/20-adhoc.conf" "${SYSTEMD_DIR}/catallenya.service.d/20-adhoc.conf"
# The one job that cannot take the base hardening. Higher-numbered so it wins over
# 10-base.conf — the unit file itself could not, since drop-ins outrank it.
cat > "${SYSTEMD_DIR}/catallenya.service.d/30-boot.conf" <<'BOOTEOF'
# Managed by systemd/install.sh — the boot orchestrator's exemption.
#
# NoNewPrivileges=true BREAKS THIS UNIT. Measured on 2026-08-13: with the base
# policy applied, `runuser -u carrein -- docker compose up -d` fails with
# "runuser: cannot set user id: Operation not permitted", so no container is ever
# started. Proven to be NNP and not the capability bound — the bound was removed
# entirely, leaving the full 41-capability set, and it still failed.
#
# runuser drops to another user through PAM, and PAM needs operations that
# no_new_privs forbids. A transient `systemd-run --property=NoNewPrivileges=yes
# runuser ... /bin/true` DOES succeed, which is why an early test wrongly cleared
# it — a transient unit is not equivalent to this one. Trust the failing unit over
# the passing probe.
#
# This is the only unit with the exemption. Every other job keeps NNP.
#
[Service]
NoNewPrivileges=false
BOOTEOF
echo "  POLICY catallenya.service: + 30-boot.conf (NoNewPrivileges exemption)"
echo "  POLICY catallenya.service: base + adhoc (copied, not linked — must resolve pre-ZFS)"

echo "Linking timer policy..."
for unit in "${!SYMLINKS[@]}"; do
    [[ "$unit" == *.timer ]] || continue
    mkdir -p "${SYSTEMD_DIR}/${unit}.d"
    ln -sf "${POLICY_DIR}/10-base-timer.conf" "${SYSTEMD_DIR}/${unit}.d/10-base-timer.conf"
    echo "  POLICY ${unit}"
done

echo "Linking instance stickers..."
for inst in "${!INSTANCE_DROPINS[@]}"; do
    mkdir -p "${SYSTEMD_DIR}/${inst}.d"
    ln -sf "${INSTANCE_DROPINS[$inst]}" "${SYSTEMD_DIR}/${inst}.d/40-instance.conf"
    echo "  POLICY ${inst}: instance sticker"
    # Only the sticker. An instance automatically inherits the TEMPLATE's drop-in
    # directory — systemd searches foo@bar.service.d/ first, then foo@.service.d/ —
    # so base, class and family already reach it through restic.check@.service.d/.
    # Verified on this box. Linking them here as well would work but would imply
    # the inheritance does not happen, which is the kind of belief that outlives
    # the code that caused it.
done

echo "Creating state directory..."
STATE_DIR_IS_NEW=0
[[ -d "${STATE_DIR}" ]] || STATE_DIR_IS_NEW=1
# `|| true` throughout: set -e is on, and this runs AFTER every symlink has been
# written. A chown that fails here must not abort an install that is already
# two-thirds applied — the failure surfaces as stale stamps, which the watchdog
# reports, rather than as a fleet installed but never enabled.
mkdir -p "${STATE_DIR}" 2>/dev/null || true
chown carrein:carrein "${STATE_DIR}" 2>/dev/null || true
chmod 0755 "${STATE_DIR}" 2>/dev/null || true
if [[ -d "${STATE_DIR}" ]]; then
    echo "  OK  ${STATE_DIR}$( (( STATE_DIR_IS_NEW )) && echo ' (new)')"
else
    echo "  !!  ${STATE_DIR} could not be created — stamps will not be written and the watchdog will report jobs stale"
fi

# --- Sanoid drop-ins ---
# These lived only on the box until now. Files under /usr are NOT dpkg conffiles,
# so an `apt upgrade` of sanoid replaces the vendor units WITHOUT prompting, after
# which the vendor ConditionFileNotEmpty points at /etc/sanoid/sanoid.conf — which
# does not exist here. A failed Condition is a SKIP: no exit code, no OnFailure=,
# no journal error, and snapshots simply stop while everything looks healthy.
#
# The empty assignments are REQUIRED: systemd APPENDS to ExecStart= and Condition*
# lists otherwise, so you would end up with both the vendor value and this one, and
# two runs per trigger.
echo "Writing sanoid drop-ins..."
for pair in "sanoid:--take-snapshots" "sanoid-prune:--prune-snapshots"; do
    svc="${pair%%:*}"; arg="${pair##*:}"
    mkdir -p "${SYSTEMD_DIR}/${svc}.service.d"
    cat > "${SYSTEMD_DIR}/${svc}.service.d/override.conf" <<EOF
# Managed by ${REPO_DIR}/systemd/install.sh — do not edit the vendor units directly.
# See the comment in install.sh for why a drop-in rather than a patched vendor unit.
[Unit]
ConditionFileNotEmpty=
ConditionFileNotEmpty=${REPO_DIR}/sanoid/sanoid.conf

[Service]
ExecStart=
ExecStart=/usr/sbin/sanoid ${arg} --verbose --configdir ${REPO_DIR}/sanoid
EOF
    echo "  OK  ${svc}.service.d/override.conf"
done

# Sanoid gets a sticker, which makes it a job as far as the watchdog is concerned
# even though it is a vendor unit we merely adopted. This is the whole reason the
# watchdog identifies jobs by "declares a Class" rather than by "is one of our
# symlinks" — the failure mode it most needs to catch belongs to a unit we do not
# own.
#
# Note the check is the ARTIFACT, not a stamp. The Condition above can fail after
# an apt upgrade, and a failed Condition is a SKIP: the unit reports no error, no
# exit code, nothing. Only the absence of new snapshots reveals it.
cat > "${SYSTEMD_DIR}/sanoid.service.d/sticker.conf" <<EOF
# Managed by ${REPO_DIR}/systemd/install.sh
#
# A vendor unit inherits no base policy, so the two contract halves the snapshot
# artifact cannot supply arrive here instead: the crash wire and a finite hang
# bound (2026-08-13 audit). The artifact covers "stopped running" — a Condition
# skip reports no failure, which was the original incident — while OnFailure=
# covers a run that genuinely dies, which the artifact only notices up to 26h
# later. The courier recognises adopted units by this sticker's merged Class=,
# not by fragment path, so no list over there needs editing.
[Unit]
OnFailure=system-ntfy@%N.service

[Service]
# Snapshot runs on this single-dataset pool finish in seconds (5,764 clean runs
# in the 30 days before 2026-08-13); the vendor unit ran at infinity, where a
# hung run is invisible forever. An hour is enormous headroom yet finite —
# sized like the rest of the fleet, worst observed times a wide margin.
TimeoutStartSec=1h

[X-Catallenya]
Class=scheduled
# sanoid.conf is daily=14 with hourly=0 and frequently=0, and sanoid.timer runs
# every 15 minutes, so a daily snapshot appears within minutes of 00:00 UTC. 26h
# catches a missed day the same day rather than the next one, with two hours of
# slack for a slow run.
MaxAge=26h
Freshness=zfs-snapshot:zpool
EOF
echo "  OK  sanoid.service.d/sticker.conf"

# sanoid-prune carries the SAME post-apt-upgrade silent-skip exposure, and had no
# sticker at all — so snapshots were proven to be taken while nothing proved they
# were still being expired. With daily=14 on a single dataset, a dead prune means
# unbounded snapshot growth whose only symptom is disk.timer at 75% pool capacity,
# by which point 14 days of retention means deleting the excess reclaims nothing
# for a fortnight.
#
# A completion stamp rather than an artifact: "snapshots were expired" leaves
# nothing observable, and the vendor unit gets no base policy, so it needs its own
# ExecStartPost. Same `-` prefix and same success-only semantics as the base.
cat > "${SYSTEMD_DIR}/sanoid-prune.service.d/sticker.conf" <<EOF
# Managed by ${REPO_DIR}/systemd/install.sh
#
# Crash wire and hang bound: same reasoning as sanoid.service.d/sticker.conf —
# a vendor unit inherits no base policy, so the contract halves the stamp
# cannot supply ride the sticker.
[Unit]
OnFailure=system-ntfy@%N.service

[Service]
ExecStartPost=-/usr/bin/touch ${STATE_DIR}/sanoid-prune
# Prune runs alongside snapshotting every 15 minutes and finishes in seconds;
# the vendor unit ran at infinity. Sizing reasoning in sanoid's sticker.
TimeoutStartSec=1h

[X-Catallenya]
Class=scheduled
# sanoid.timer fires prune every 15 minutes alongside snapshotting. 26h matches
# the sanoid sticker and catches a stopped prune the same day.
MaxAge=26h
Freshness=stamp:${STATE_DIR}/sanoid-prune
EOF
echo "  OK  sanoid-prune.service.d/sticker.conf"

# --- Seed completion stamps -------------------------------------------------
#
# A job's stamp does not exist until its first successful run, so without seeding
# the first roll call would report every stamp-checked job as NEVER RAN — dozens of
# findings on day one, none of them real. Seeding says "the contract starts now",
# which is true: before this install these jobs had no completion record at all, so
# reporting their absence would be reporting a pre-existing gap rather than a
# failure.
#
# Only ever creates a MISSING stamp. Re-running install.sh must not refresh an
# existing one — that would reset the clock on a job that has genuinely stopped and
# hide it from the very next round.
# Seed ONLY when the state directory did not exist — i.e. the very first install.
#
# The old rule was "seed any missing stamp", and the set of missing stamps is
# exactly the set of jobs that have NOT completed successfully since the last run.
# Since this script advertises itself as idempotent, every later re-run bought the
# broken set another full MaxAge of silence — up to 40 days for restic.check@subset
# or zpool.scrub, and it was 400 for the yearly restic.check@data this rule was
# written against (retired 2026-08-22; the argument survives its example).
# Seeding is a statement that the contract starts now, which is true once.
echo "Seeding completion stamps..."
seeded=0
if (( ! STATE_DIR_IS_NEW )); then
    echo "  skipped (state directory already existed — seeding again would reset the clock on any job that has genuinely stopped)"
fi
for unit in "${!SYMLINKS[@]}" "catallenya.service"; do
    [[ "$unit" == *.service ]] || continue
    [[ -n "${PLUMBING[$unit]:-}" ]] && continue
    [[ "$unit" == *@.service ]] && continue
    src="${SYMLINKS[$unit]:-${SYSTEMD_DIR}/${unit}}"
    [[ -f "$src" ]] || continue
    class=$(sticker "$src" Class)
    fresh=$(sticker "$src" Freshness)
    # Monitors imply a stamp rather than declaring one.
    [[ "$class" == "monitor" && -z "$fresh" ]] && fresh="stamp:${STATE_DIR}/${unit%.service}"
    [[ "$fresh" == stamp:* ]] || continue
    path="${fresh#stamp:}"
    if (( STATE_DIR_IS_NEW )) && [[ ! -e "$path" ]]; then
        # `|| true`: a stamp we cannot write must never abort an install that has
        # already created 31 symlinks. It goes stale instead and the watchdog says so.
        touch "$path" 2>/dev/null && chown carrein:carrein "$path" 2>/dev/null || true
        [[ -e "$path" ]] && { echo "  SEED ${unit%.service}"; seeded=$((seeded + 1)); }
    fi
done
# Template instances name their stamps in the instance sticker.
for inst in "${!INSTANCE_DROPINS[@]}"; do
    fresh=$(sticker "${INSTANCE_DROPINS[$inst]}" Freshness)
    [[ "$fresh" == stamp:* ]] || continue
    path="${fresh#stamp:}"
    if (( STATE_DIR_IS_NEW )) && [[ ! -e "$path" ]]; then
        touch "$path" 2>/dev/null && chown carrein:carrein "$path" 2>/dev/null || true
        [[ -e "$path" ]] && { echo "  SEED ${inst%.service}"; seeded=$((seeded + 1)); }
    fi
done
(( seeded == 0 )) && echo "  none (all stamps already present)"

# =============================================================================
# Prune what no longer belongs
# =============================================================================
#
# This script created and repaired links but never removed them, so retiring a unit
# left its symlink behind pointing at a deleted file — including the enable links
# under */.wants/, which `systemctl disable` can no longer clean once the unit file
# is gone.
#
# The mount check is not paranoia: every target lives on /zpool, so if ZFS is not
# mounted then EVERY project link looks dangling and this loop would delete the lot.
if [[ ! -f "${REPO_DIR}/docker-compose.yml" ]]; then
    echo "Error: ${REPO_DIR} looks unmounted or wrong — refusing to prune"
    exit 1
fi

echo "Pruning retired units..."
pruned=0
while IFS= read -r link; do
    target="$(readlink "$link")"
    [[ "$target" == "${REPO_DIR}"/* ]] || continue
    unit="$(basename "$link")"
    systemctl stop "$unit" 2>/dev/null || true
    rm -f "$link"
    echo "  DEL ${link#"${SYSTEMD_DIR}"/} (target gone: ${target})"
    pruned=$((pruned + 1))
done < <(find "${SYSTEMD_DIR}" -maxdepth 3 -xtype l)

# Orphaned .d/ directories, left by a unit that was retired.
# Only OUR drop-in directories, identified by containing a symlink into the repo.
#
# The previous rule was "no unit file of that name in /etc/systemd/system" — which
# is the NORMAL state for every vendor unit, since those live in /usr/lib. It would
# have deleted /etc/systemd/system/sshd-keygen@.service.d/ (openssh-server's, and
# the reason sshd regenerates keys correctly under cloud-init), plus any override
# anyone ever adds for docker or tailscaled. The two hardcoded sanoid exemptions
# were evidence it had already been hit once and patched per-instance rather than
# at the rule.
for dir in "${SYSTEMD_DIR}"/*.d; do
    [[ -d "$dir" ]] || continue
    unit="$(basename "${dir%.d}")"
    # Ours if it holds at least one symlink into the repo. A vendor .d/ holds only
    # regular files and is skipped untouched.
    ours=0
    for f in "$dir"/*; do
        [[ -L "$f" && "$(readlink -f "$f")" == "${REPO_DIR}"/* ]] && { ours=1; break; }
    done
    (( ours )) || continue
    # A template INSTANCE never has a unit file of its own — restic.check@subset
    # is served by restic.check@.service. Testing "is there a file with this name"
    # therefore deleted the instance sticker directories this same script had just
    # created, thirty lines earlier, leaving both check jobs with no MaxAge or
    # Freshness and silently unmonitored. An instance is legitimate if its TEMPLATE
    # is installed.
    if [[ "$unit" == *@*.service && "$unit" != *@.service ]]; then
        [[ -e "${SYSTEMD_DIR}/${unit%%@*}@.service" ]] && continue
    fi
    if [[ ! -e "${SYSTEMD_DIR}/${unit}" ]]; then
        rm -rf "$dir"
        echo "  DEL ${unit}.d (unit gone)"
        pruned=$((pruned + 1))
    else
        # Shadow drop-ins: anything in OUR directory that we did not put there can
        # silently override the policy, and link_policy only ever pruned 20-*/30-*.
        for f in "$dir"/*; do
            [[ -e "$f" ]] || continue
            case "$(basename "$f")" in
                10-base.conf|10-base-timer.conf|20-*.conf|30-*.conf|40-instance.conf) continue ;;
            esac
            rm -f "$f"
            echo "  DEL ${unit}.d/$(basename "$f") (unmanaged drop-in shadowing policy)"
            pruned=$((pruned + 1))
        done
    fi
done
(( pruned == 0 )) && echo "  none"

# =============================================================================
# Reload and enable
# =============================================================================

echo "Reloading systemd daemon..."
systemctl daemon-reload

echo "Enabling catallenya.service..."
systemctl enable catallenya.service

# --now so a NEWLY added timer starts immediately rather than lying dormant until
# the next reboot. Existing timers are active only because catallenya.service
# starts them at boot; without --now, adding a timer here and not rebooting means
# its job silently never runs.
echo "Enabling timers..."
for unit in "${!SYMLINKS[@]}"; do
    [[ "$unit" == *.timer ]] || continue
    systemctl enable --now "$unit"
    echo "  ${unit}"
done

# Path units are event-triggered rather than scheduled, so they must also be
# STARTED — an enabled-but-unstarted path unit watches nothing until the next boot,
# and the pipeline would look installed while silently doing nothing.
echo "Enabling path units..."
for unit in "${!SYMLINKS[@]}"; do
    [[ "$unit" == *.path ]] || continue
    systemctl enable --now "$unit"
    echo "  ${unit}"
done

echo ""
echo "Done."
echo "  ${#SYMLINKS[@]} units installed, all satisfying the contract"
echo ""
echo "Verify with:"
echo "  systemctl status catallenya"
echo "  systemctl cat afterimage.triage.service        # see the merged policy"
echo "  systemctl show afterimage.triage.service -p StartLimitIntervalUSec -p OnFailure"
