#!/bin/bash
# The roll call.
#
# Every other alarm here answers "did this job CRASH". This one answers the
# question nothing else could: "did this job actually RUN, and did it do anything".
#
# Silent when healthy, like restic.staleness and changedetection.health. A daily
# "all fine" ping is noise you learn to swipe away, and an alarm nobody reads is
# not an alarm. The journal gets the full roll call either way — phone for action,
# journal for forensics.
#
# NOT `set -e`. One unreadable unit or one wedged zfs command must not abort the
# round: a watchdog that dies partway is a watchdog that silently reports nothing
# for everything it never reached, which is precisely the failure it exists to
# catch. Every check below is individually guarded instead.
set -uo pipefail

# The host-health channel, carrying boot events and watchdog findings alike.
#
# Renamed from `boot` on 2026-08-13, and the ORDER mattered: subscribe first, test
# publish, confirm arrival, and only then flip. ntfy creates a topic on first
# publish and returns 200 OK, so flipping first would have dropped every finding on
# the floor — the exact failure this watchdog exists to prevent, committed by the
# watchdog itself. Changed together with catallenya.sh and system-ntfy.sh's
# HOST_TOPIC; they must never disagree.
# shellcheck disable=SC2034  # read by ntfy.lib.sh, sourced below
NTFY_TOPIC="${HEARTBEAT_NTFY_TOPIC:-host}"

# Notification transport is shared. This replaced a wholesale `source` of the root
# .env — forty-odd credentials, to build one URL out of three of them — plus a
# private curl. ntfy.lib.sh extracts only those three keys, and brings --max-time
# and hdr_safe with it.
#
# Absolute path on purpose. REPO_DIR below is overridable so the offline suite can
# run the roll call against a scratch tree, and the transport must not follow it
# there: the tree holds fixture units, not this repo's code.
#
# NTFY_MARKDOWN is GONE (2026-08-21). It was `no` here for a real reason: findings
# are machine-built lines carrying unit names, stamp paths and quoted sticker values,
# and under a renderer a pair of underscores in a path would italicise the middle of a
# finding — the one thing a watchdog message must be is literal. body_list() escapes
# every line it renders, so the literalness now comes from the renderer rather than
# from switching rendering off.

# A STABLE SEQUENCE ID, so a condition that persists is ONE message that keeps being
# replaced rather than a pile. Runs DAILY, and a stale job stays stale — the same finding arrived every morning until
# someone acted on it.
#
# It does NOT self-clear when the condition goes away. A fault has no buttons, and a
# notification without buttons is never withdrawn by the system: an absent message is
# ambiguous — fixed, mis-swiped, or never sent — and a stale one is not. See
# ntfy/MESSAGES.md.
WATCHDOG_NTFY_ID="watchdog-findings"
# shellcheck source=/zpool/catallenya/ntfy/ntfy.lib.sh
source "/zpool/catallenya/ntfy/ntfy.lib.sh"

# Both overridable for the offline suite only, which points them at a scratch tree
# and the per-user systemd manager. That lets every finding type be provoked with
# real systemd doing the parsing, rather than a mock that agrees with whatever the
# script already believes. Defaults are the real system; nothing else sets these.
SYSTEMD_DIR="${HEARTBEAT_SYSTEMD_DIR:-/etc/systemd/system}"
REPO_DIR="${HEARTBEAT_REPO_DIR:-/zpool/catallenya}"
SYSTEMCTL="${HEARTBEAT_SYSTEMCTL:-systemctl}"

# Units that are not ours but whose silence is ours to worry about. Each MUST
# resolve to a job with a sticker; if one does not, that is itself the finding.
# Everything else is discovered, but these three cannot be: catallenya.service is
# a regular file rather than a symlink (it must load before ZFS mounts), and the
# sanoid pair are vendor units whose stickers live only in a drop-in. They are
# also, not coincidentally, the units whose documented failure mode is stopping
# silently — so "absent" must never read as "fine".
# Overridable so the offline suite can run against a scratch tree where these do
# not exist; nothing but the tests ever sets it.
read -r -a ADOPTED <<<"${HEARTBEAT_ADOPTED-catallenya.service sanoid.service sanoid-prune.service}"

FINDINGS=()
FINDINGS_LOG=()
NOTES=()
# A FINDING IS AN ITEM AND A DETAIL: the unit is the thing, the type and explanation
# are what happened to it. It used to be one padded line joined by an em-dash —
# `STALE         restic.backup — 2d 4h since last run` — which the body language bans
# twice over, and the indent does the column's job anyway.
#
# THE JOURNAL FORM IS UNCHANGED and kept in its own array. A log line is read in a
# terminal, where the padded SCREAMING column is how you find the type at a glance and
# a tab is not an indent — so the two audiences get two renderings of one call rather
# than one rendering that suits neither.
finding() {
    FINDINGS+=("$2"$'\t'"$1: $3")
    FINDINGS_LOG+=("$(printf '%-13s %s — %s' "${1^^}" "$2" "$3")")
}

# NOTES never reach the phone — they are findings explained by downtime, printed and
# dropped — so they keep the padded terminal shape.
note()    { NOTES+=("$(printf '%-13s %s' "$1" "$2")"); }

# --- helpers ---------------------------------------------------------------

# How long this box has been up. Used to tell "the job stopped" apart from "the
# box was off", which are indistinguishable from a stamp alone. Overridable for
# the offline suite only, which cannot reboot the box to exercise both branches
# of the downtime check; nothing else sets it.
UPTIME_S=${HEARTBEAT_UPTIME_S:-$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null || echo 0)}

# How long after boot a stale artifact is still explained by catch-up rather than
# reported. 24h: no scheduled job can run longer than restic.check@subset's
# TimeoutStartSec=12h, and the roll call is daily, so one full cycle of grace
# covers every job that is going to self-heal. See stale_or_downtime.
BOOT_GRACE_S=${HEARTBEAT_BOOT_GRACE_S:-86400}

# systemd's own time parser, so MaxAge accepts anything a timer would — but the
# result must be a plain finite integer we can compare.
#
# `MaxAge=infinity` parses to 18446744073709551615 µs, which awk renders as
# 1.84467e+13 and bash then refuses to compare, so `(( age > max ))` errors and the
# check SILENTLY PASSES. A MaxAge that disables its own check is worse than no
# MaxAge, so anything beyond ten years is rejected outright and surfaces as a bad
# sticker. Length rather than arithmetic, because the raw value overflows int64.
to_seconds() {
    local out us
    out=$(systemd-analyze timespan "$1" 2>/dev/null) || return 1
    us=$(awk 'NR==2 {print $NF}' <<<"$out")
    [[ "$us" =~ ^[0-9]+$ ]] || return 1
    (( ${#us} > 15 )) && return 1          # >~31 years, or infinity
    echo $(( us / 1000000 ))
}

human() {
    local s=$1
    (( s < 0 )) && s=0
    if   (( s < 3600 ))  ; then printf '%dm' $(( s / 60 ))
    elif (( s < 86400 )) ; then printf '%dh %dm' $(( s / 3600 )) $(( (s % 3600) / 60 ))
    else                        printf '%dd %dh' $(( s / 86400 )) $(( (s % 86400) / 3600 ))
    fi
}

# Report staleness, unless the box simply has not been up long enough for the
# missed run to have caught up yet. This host has no UPS, goes fully dark on AC
# loss, and every timer is Persistent=true — so the boot after an outage fires a
# dozen catch-up runs at once. Without this, that boot produces a burst of
# high-priority pushes that all self-resolve within hours, which is the fastest
# way to train someone to mute the topic. Downtime is logged, never pushed.
#
# The window is min(MaxAge, BOOT_GRACE_S), NOT MaxAge alone. The first version
# compared uptime against MaxAge, which muted exactly the jobs this check matters
# most for: the then-yearly restic.check@data (MaxAge=400d, retired 2026-08-22)
# could never page unless the box stayed up 400 days straight, and any reboot
# muted every long-cadence job for its whole MaxAge — a disabled zpool.scrub.timer
# would have stayed silent forever on a box that reboots more often than every 40
# days (2026-08-13 audit). 40d is now the longest MaxAge in the repo, so the
# motivating example is gone but the failure it describes is one 40d job away.
# A day of grace is enough for every catch-up that is going to happen, and a
# catch-up that FAILS already pages through the inherited OnFailure=. The min()
# keeps the old, tighter window for jobs whose MaxAge is under a day.
stale_or_downtime() {   # $1 unit, $2 age, $3 max, $4 literal, $5 description
    local grace=$3
    (( grace > BOOT_GRACE_S )) && grace=${BOOT_GRACE_S}
    if (( UPTIME_S < grace )); then
        note "WAS OFF" "$1 — $5 $(human "$2") (max $4), but the box has only been up $(human "$UPTIME_S")"
    else
        finding "Stale" "$1" "$5 $(human "$2") (max $4)"
    fi
}

# Read a key from the MERGED view. `systemctl cat` concatenates the fragment then
# every drop-in in precedence order, so taking the LAST match gives the effective
# value — which is how restic.check@subset picks up its instance sticker rather
# than the template's silence.
sticker() {
    $SYSTEMCTL cat "$1" 2>/dev/null | awk -v k="$2" '
        /^\[/  { inside = ($0 == "[X-Catallenya]"); next }
        inside && index($0, k "=") == 1 { v = substr($0, length(k) + 2) }
        END { if (v != "") print v }
    '
}

# --- candidate jobs --------------------------------------------------------
#
# A unit is a job if it declares a Class. That is the whole rule, and it means the
# watchdog needs no list of its own to fall out of date — a job registered with
# install.sh is a job here, automatically.
candidates() {
    local u
    for u in "${SYSTEMD_DIR}"/*.service; do
        [[ -e "$u" ]] || continue
        u=$(basename "$u")
        [[ "$u" == *@.service ]] && continue     # templates are not runnable
        echo "$u"
    done
    # Template instances are named by the timers that fire them, never by a file.
    local t target
    for t in "${SYSTEMD_DIR}"/*.timer; do
        [[ -e "$t" ]] || continue
        target=$(grep -m1 '^Unit=' "$t" 2>/dev/null | cut -d= -f2-)
        [[ -n "$target" ]] && echo "$target"
    done
    printf '%s\n' "${ADOPTED[@]}"
}

# --- freshness checks ------------------------------------------------------

check_stamp() {          # $1 unit, $2 path, $3 max_seconds, $4 maxage_literal
    if [[ ! -e "$2" ]]; then
        finding "Never ran" "$1" "no completion stamp at $2"
        return
    fi
    local age=$(( $(date +%s) - $(stat -c %Y "$2") ))
    (( age > $3 )) && stale_or_downtime "$1" "$age" "$3" "$4" "last completed"
    return 0
}

check_unit_armed() {     # $1 job, $2 unit to check
    local st; st=$($SYSTEMCTL is-active "$2" 2>/dev/null)
    [[ "$st" == "active" ]] || finding "Unarmed" "$1" "$2 is $st, so nothing is watching"
}

# An armed watcher proves the inotify watch exists. It does NOT prove anything can
# ever reach it: a .path unit reports `active` even when the thing that writes into
# the watched directory is dead, so "you took no screenshots this week" and "the
# uploader is down" look identical. Producer= names the feeder so they don't.
#
# A floor, not a proof — this catches a stopped container, not a running Syncthing
# with the folder paused.
check_producer() {       # $1 job, $2 producer spec
    case "$2" in
        container:*)
            local c="${2#container:}" state
            state=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null) || {
                finding "No producer" "$1" "container '$c' does not exist, so nothing can ever arrive"; return; }
            [[ "$state" == "running" ]] || \
                finding "No producer" "$1" "container '$c' is $state, so nothing can ever arrive"
            ;;
        *) finding "Bad sticker" "$1" "Producer='$2' is not a recognised form (expected container:<name>)" ;;
    esac
}

check_zfs_snapshot() {   # $1 job, $2 dataset, $3 max_seconds, $4 literal
    local newest; newest=$(zfs list -t snapshot -H -o creation -S creation "$2" 2>/dev/null | head -1)
    if [[ -z "$newest" ]]; then
        finding "Never ran" "$1" "no snapshots exist on $2"
        return
    fi
    local ts; ts=$(date -d "$newest" +%s 2>/dev/null) || { finding "Unknown" "$1" "cannot parse snapshot date '$newest'"; return; }
    local age=$(( $(date +%s) - ts ))
    (( age > $3 )) && stale_or_downtime "$1" "$age" "$3" "$4" "newest snapshot is"
    return 0
}

check_zfs_scrub() {      # $1 job, $2 pool, $3 max_seconds, $4 literal
    local scan; scan=$(zpool status "$2" 2>/dev/null | sed -n 's/^[[:space:]]*scan: //p')
    if [[ -z "$scan" ]]; then
        finding "Unknown" "$1" "no scan line in zpool status $2"
        return
    fi
    # `scan:` is shared by scrub AND resilver. Matching loosely would let a disk
    # replacement's "resilvered ... on <date>" pass as a completed scrub for a
    # whole MaxAge, and would read "resilver in progress" as a healthy scrub.
    if [[ "$scan" != scrub* ]]; then
        finding "Unknown" "$1" "last ZFS scan on $2 was not a scrub ('${scan%% *}'), so scrub age is unknown"
        return
    fi
    [[ "$scan" == *"in progress"* ]] && return 0     # a running scrub is the best answer
    local when; when=$(sed -n 's/.* on \(.*\)$/\1/p' <<<"$scan")
    local ts; ts=$(date -d "$when" +%s 2>/dev/null) || { finding "Unknown" "$1" "cannot parse scrub date '$when'"; return; }
    local age=$(( $(date +%s) - ts ))
    (( age > $3 )) && stale_or_downtime "$1" "$age" "$3" "$4" "last scrub completed"
    return 0
}

check_boot() {           # $1 job
    # NOT `Result`. A ServiceResult is `success` for a unit that has never run —
    # and for one that does not exist at all, both verified on this box. Since
    # catallenya.service is RemainAfterExit=yes, a boot that actually completed
    # leaves it active; anything else means the orchestrator did not finish, so no
    # timers were started, no path units armed and no containers brought up.
    local active load
    active=$($SYSTEMCTL show "$1" -p ActiveState --value 2>/dev/null)
    load=$($SYSTEMCTL show "$1" -p LoadState --value 2>/dev/null)
    if [[ "$load" != "loaded" ]]; then
        finding "Missing" "$1" "LoadState=$load, so nothing orchestrates boot"
    elif [[ "$active" != "active" ]]; then
        finding "Failed" "$1" "ActiveState=$active, so the last boot did not finish orchestrating"
    fi
}

# --- the round -------------------------------------------------------------

echo "heartbeat: starting roll call (up $(human "$UPTIME_S"))"
CHECKED=0

while read -r unit; do
    [[ -n "$unit" ]] || continue

    # A masked unit reports no sticker and would otherwise vanish from the roll
    # call without a word — and masking is this box's standard "make it stop"
    # reflex (avahi is masked deliberately). Silence must not be how a job leaves.
    load=$($SYSTEMCTL show "$unit" -p LoadState --value 2>/dev/null)
    if [[ "$load" == "masked" ]]; then
        # Only OURS. avahi-daemon and friends are masked on purpose here, and a
        # watchdog that complains daily about a deliberate decision is a watchdog
        # you learn to ignore. A masked unit reports no sticker, so ownership has to
        # be established structurally: it is ours if we installed it as a symlink
        # into the repo, or if it is one we adopted.
        is_ours=0
        [[ -L "${SYSTEMD_DIR}/${unit}" && "$(readlink -f "${SYSTEMD_DIR}/${unit}")" == "${REPO_DIR}"/* ]] && is_ours=1
        for a in "${ADOPTED[@]}"; do [[ "$unit" == "$a" ]] && is_ours=1; done
        (( is_ours )) && finding "Masked" "$unit" "masked, so it cannot run at all"
        continue
    fi

    class=$(sticker "$unit" Class)
    if [[ -z "$class" ]]; then
        # Adopted units MUST carry a sticker; losing one is how they'd go quiet.
        for a in "${ADOPTED[@]}"; do
            [[ "$unit" == "$a" ]] && finding "No sticker" "$unit" "adopted job with no Class; its sticker is gone" && break
        done
        continue                            # anything else is plumbing or vendor
    fi
    CHECKED=$((CHECKED + 1))

    maxage=$(sticker "$unit" MaxAge)
    freshness=$(sticker "$unit" Freshness)

    # A monitor's Freshness is implied rather than declared: it produces nothing
    # but its own stamp, so there is never anything else to check.
    if [[ "$class" == "monitor" && -z "$freshness" ]]; then
        freshness="stamp:${REPO_DIR}/systemd/state/${unit%.service}"
    fi

    if [[ -z "$freshness" ]]; then
        finding "No sticker" "$unit" "Class=$class but no Freshness to check"
        echo "  ?? $unit (class=$class, no freshness)"
        continue
    fi

    max_s=0
    if [[ -n "$maxage" ]]; then
        max_s=$(to_seconds "$maxage") || { finding "Bad sticker" "$unit" "MaxAge='$maxage' is not a usable timespan"; continue; }
    fi

    case "$freshness" in
        stamp:*)        [[ -n "$maxage" ]] && check_stamp        "$unit" "${freshness#stamp:}"        "$max_s" "$maxage" ;;
        unit:*)         check_unit_armed  "$unit" "${freshness#unit:}" ;;
        zfs-snapshot:*) check_zfs_snapshot "$unit" "${freshness#zfs-snapshot:}" "$max_s" "$maxage" ;;
        zfs-scrub:*)    check_zfs_scrub    "$unit" "${freshness#zfs-scrub:}"    "$max_s" "$maxage" ;;
        boot)           check_boot        "$unit" ;;
        *)              finding "Bad sticker" "$unit" "Freshness='$freshness' is not a recognised form" ;;
    esac

    producer=$(sticker "$unit" Producer)
    [[ -n "$producer" ]] && check_producer "$unit" "$producer"

    echo "  ok $unit (class=$class, freshness=$freshness${producer:+, producer=$producer})"
done < <(candidates | sort -u)

# --- timers ----------------------------------------------------------------
#
# A stale stamp catches a dead timer for most jobs. The exception is a timer that
# fires an ADHOC job, whose freshness is "is the watcher armed" — nothing about
# that changes when the timer dies. pigeonhole.backstop.timer is exactly this: it
# fires pigeonhole.triage.service and is the sole cover for a file type no
# PathExistsGlob matches. Losing it would be invisible.
for t in "${SYSTEMD_DIR}"/*.timer; do
    [[ -e "$t" ]] || continue
    tname=$(basename "$t")
    tstate=$($SYSTEMCTL is-active "$tname" 2>/dev/null)
    [[ "$tstate" == "active" ]] || finding "Timer dead" "$tname" "is $tstate, so its job is no longer scheduled"
done

# --- drift: a job that escaped the contract --------------------------------
#
# The one hole in the sticker model is a job that never got one. It closes here:
# anything installed from this repo that does not declare a Class is either
# plumbing (there is exactly one, and it is named) or an oversight.
#
# Note this pass sees only SYMLINKS, which is why the adopted units above are
# asserted separately — catallenya.service is a regular file and sanoid's fragment
# lives under /usr, so neither could ever appear here.
for link in "${SYSTEMD_DIR}"/*.service "${SYSTEMD_DIR}"/*.timer "${SYSTEMD_DIR}"/*.path; do
    [[ -L "$link" ]] || continue
    [[ "$(readlink -f "$link")" == "${REPO_DIR}"/* ]] || continue
    unit=$(basename "$link")
    [[ "$unit" == "system-ntfy@.service" ]] && continue     # plumbing, deliberately
    [[ "$unit" == *.service ]] || continue                  # timers/paths carry no sticker
    [[ "$unit" == *@.service ]] && continue
    [[ -n "$(sticker "$unit" Class)" ]] && continue
    finding "No sticker" "$unit" "installed from the repo but declares no Class"
done

# --- units sitting in `failed` ---------------------------------------------
#
# A unit's FAILURE is announced exactly once, at the moment it fails, by the courier
# — and if that one alert never lands, nothing ever mentions it again. Everything
# above this line asks "did the job run recently enough", which a failed unit can
# still satisfy: a job that ran, failed, and left a stale-but-not-yet-stale stamp
# looks fine to every check here.
#
# That single point of failure was real on 2026-08-14: liquidroom.triage failed 13
# times, seven alerts were destroyed by the courier's rate limit and the other five
# were titled "Success". Both faults are fixed now (see system-ntfy@.service and
# system-ntfy.sh), which is exactly why this belongs here — those fixes make the
# first alert reliable, and this makes it non-unique. A daily sweep costs one
# systemctl call and turns "you had to catch the notification" into "it is reported
# every morning until it is cleared".
#
# --plain --no-legend so the output is parseable; the unit name is the first field.
while read -r fu _; do
    [[ -n "$fu" ]] || continue
    # The courier itself is deliberately excluded from the sticker model, but a
    # courier stuck in `failed` is worth saying out loud — it means an alert about
    # something else did not get out.
    finding "Failed" "$fu" "is sitting in failed and nothing will mention it again"
done < <($SYSTEMCTL list-units --state=failed --plain --no-legend --no-pager 2>/dev/null | awk '{print $1}')

# --- report ----------------------------------------------------------------

if (( ${#NOTES[@]} )); then
    echo "heartbeat: ${#NOTES[@]} finding(s) explained by downtime, not pushed:"
    printf '%s\n' "${NOTES[@]}"
fi

echo "heartbeat: checked ${CHECKED} job(s), ${#FINDINGS[@]} finding(s)"

if (( ${#FINDINGS[@]} == 0 )); then
    echo "heartbeat: all clear"
    # Findings the next run resolved — a late job that ran, a unit that recovered —
    # turn yesterday's "Watchdog: N Findings" into "Watchdog: All Clear" in place
    # (ntfy.lib.sh fault_close, the recovery rule). No marker, no message.
    send_out="$(fault_close "$WATCHDOG_NTFY_ID" "All Clear" "Every job checked in on time." 2>&1)"
    if [[ -n "$send_out" ]]; then
        echo "heartbeat: ntfy publish FAILED — the all-clear was not delivered: ${send_out}" >&2
        exit 1
    fi
    exit 0
fi

# The journal gets the full roll call, flattened, BEFORE the wire — if delivery
# fails these lines are the only surviving record of what was found.
printf '%s\n' "${FINDINGS_LOG[@]}"

# --all, NOT the five-item cap.
#
# This is the second list in the repo that must show every member, and for the same
# reason pigeonhole's staged batch does: a finding you cannot see is a finding you do
# not fix, and there is no button here to make the omission obvious. The body is
# bounded by the number of installed units, so the 4096-byte attachment threshold is
# only reachable on a box where nearly every job has failed at once — a situation you
# would already know about by other means.
BODY="$(body_list --all "${FINDINGS[@]}")"
# The transport's own mute seam, asked directly rather than re-read here, so the
# offline suites exercise everything up to the wire without putting anything on the
# phone. The message is this script's own: the suite pins it.
if ntfy_muted; then
    echo "heartbeat: NTFY_DISABLE=1, not publishing"
    exit 0
fi

# A failed publish EXITS NON-ZERO so the inherited OnFailure= fires. Without this
# a dead ntfy, a wrong URL or an unreachable tailnet is indistinguishable from a
# healthy round: findings would print to a journal nobody reads and the unit would
# still succeed and stamp itself fresh.
#
# notify() cannot report that failure by exit code — it is best-effort by design and
# ends every path in `|| true`, so that a pipeline's own work is never failed by a
# notification about it. This job is the inverse: the notification IS the work. So
# the transport's silence is the test. curl -fsS prints nothing on a successful
# publish and prints the failure otherwise, and _ntfy_env logs when it declines to
# build a URL at all; anything the transport says here is an undelivered finding.
# `Watchdog: 3 Findings`, not a bare `Watchdog`. The subject does not repeat the
# topic — this publishes to `host`, which also carries boot and rerouted alerts — and
# the state carries the count, which is the fact you previously had to open the
# notification to learn.
n_find=${#FINDINGS[@]}
send_out="$(fault_open "$WATCHDOG_NTFY_ID" "$(title_state Watchdog "${n_find} Finding$( (( n_find == 1 )) || printf s )")" "$BODY" 2>&1)"
if [[ -n "$send_out" ]]; then
    echo "heartbeat: ntfy publish FAILED — ${#FINDINGS[@]} finding(s) undelivered: ${send_out}" >&2
    exit 1
fi
