#!/bin/bash
set -euo pipefail

# The alarm of last resort. Every OnFailure= in the fleet points here, so this script
# deliberately DOES NOT source ntfy/ntfy.lib.sh — owner's call, and the reason is the
# position rather than the code: the one job whose whole purpose is to speak when
# something else has broken should depend on as little as possible, including on
# another file in this repo being intact. It is the only publisher in the tree with
# that exemption. The cost is that the two lines of curl below have to keep pace with
# the transport by hand; the flags carry the reasons inline for that.

# Source root .env
ROOT_ENV="/zpool/catallenya/.env"
if [[ -f "$ROOT_ENV" ]]; then
    # shellcheck source=/dev/null  # runtime-only file, not in the repo
    source "$ROOT_ENV"
else
    echo "Root .env not found at $ROOT_ENV"
    exit 1
fi

# Interpolate NTFY_URL after sourcing
NTFY_URL="https://${TAILNET_DOMAIN}.${TAILNET_DNS_NAME}:${NTFY_REVERSE_PROXY_PORT}"

service_name="$1"

# Split "<topic>.<job>" — the unit naming convention already carries the topic, so
# restic.backup -> restic/Backup, afterimage.triage -> afterimage/Triage. This used to
# match restic and nothing else, while FOUR units wired OnFailure= here through the
# system-ntfy@.service template: capture.{triage,sweep} and documents.{triage,apply}.
# All four hit the else branch and died with "Unknown service type", so their alerts
# were never delivered — silently, because systemd does not report a failed
# OnFailure= handler anywhere. Deriving the topic fixes every one of them at once and
# needs no edit for the next job that follows the convention.
topic="${service_name%%.*}"
job_type="${service_name#*.}"

# A single-word unit name has no topic to split off, so it is its own. This is not
# a broken caller — catallenya.service is exactly that shape, and since every job
# now inherits OnFailure= from the base policy, the boot orchestrator reaches here
# too. An earlier version rejected these outright.
if [[ "$service_name" != *.* ]]; then
    topic="$service_name"
    job_type="$service_name"
fi

# --- Is this one of ours? ---
#
# This replaces a hand-maintained `case` allowlist of five topic names. That list
# had already eaten alerts once: four units wired OnFailure= here through the
# template and every one hit the else branch and died with "Unknown service type",
# silently, because systemd does not report a failed OnFailure= handler anywhere.
# Fixing the list is a fix that lasts until the next unit; asking the system is a
# fix that lasts.
#
# The question the allowlist was really asking is "did we install this unit", and
# systemd can answer it directly. A typo'd or foreign unit has no fragment under
# the repo and is still refused — which was the point of the list.
fragment=$(systemctl show "${service_name}.service" -p FragmentPath --value 2>/dev/null)
if [[ -z "$fragment" ]] || [[ "$(readlink -f "$fragment" 2>/dev/null)" != /zpool/catallenya/* ]]; then
    # Adopted units fail the fragment test yet are ours: catallenya.service is
    # written to /etc (it must load before ZFS mounts), and the sanoid pair are
    # vendor fragments under /usr whose only catallenya-ness is the sticker
    # drop-in install.sh gives them. What marks a unit as ours everywhere else
    # is that merged Class= — so ask the same question the watchdog asks,
    # rather than keeping a name list here: the last hand-maintained list in
    # this script silently ate four units' alerts. A foreign or typo'd unit has
    # no sticker and is still refused. Same awk as the watchdog's sticker():
    # section-aware, last match wins.
    class=$(systemctl cat "${service_name}.service" 2>/dev/null | awk '
        /^\[/  { inside = ($0 == "[X-Catallenya]"); next }
        inside && index($0, "Class=") == 1 { v = substr($0, 7) }
        END { if (v != "") print v }')
    if [[ -z "$class" ]]; then
        echo "Not a catallenya unit, refusing to publish: ${service_name} (fragment: ${fragment:-none})"
        exit 1
    fi
fi

# --- Where does it go? ---
#
# Deriving the topic from the unit name is what makes a new job work with no edit
# here. What cannot be derived is whether a PHONE is subscribed to the result:
# ntfy creates a topic on first publish, so an unsubscribed one accepts the alert
# with a 200 OK and drops it on the floor.
#
# So rather than refuse an unknown topic — which guarantees the alert is lost —
# route it to the host-health channel with its intended topic in the title, which
# guarantees it is delivered. Worst case you get a correctly-labelled alert on the
# wrong-but-watched channel.
#
# This is not hypothetical: catallenya and catallenya.heartbeat both derive the
# topic `catallenya`, which is not subscribed and never will be.
#
# Renamed from `boot` on 2026-08-13 after the phone was subscribed and a test
# publish confirmed, never before — an unsubscribed topic accepts a publish with a
# 200 OK and discards it.
HOST_TOPIC="host"
SUBSCRIBED="restic afterimage pigeonhole ebooks immich changedetection disk zpool liquidroom grayjay ${HOST_TOPIC}"

routed_note=""
if [[ " ${SUBSCRIBED} " != *" ${topic} "* ]]; then
    routed_note=" [${topic}]"
    topic="${HOST_TOPIC}"
fi

# Handle special cases
if [[ "$job_type" == "check@meta" ]]; then
    job_type="Check Metadata"
elif [[ "$job_type" == "check@data" ]]; then
    job_type="Check Data"
elif [[ "$job_type" == "check@subset" ]]; then
    job_type="Check Data Subset"
elif [[ "$job_type" == "fix-rotations" ]]; then
    # Plain capitalisation gives "Fix-rotations Failure". Match the unit's own
    # Description instead, for the same reason check@meta is spelled out.
    job_type="Rotation Bake"
else
    # Capitalize first letter for other jobs
    job_type="$(tr '[:lower:]' '[:upper:]' <<< ${job_type:0:1})${job_type:1}"
fi

# THE ONE PLACE IN THE REPO THAT BUILDS A TITLE BY HAND.
#
# ntfy/kinds.sh has title_state() for exactly this shape and this file deliberately
# does not use it — for the same reason it does not source ntfy/ntfy.lib.sh. This is
# the alarm of last resort that every OnFailure= points at, and it must depend on as
# little as possible, including on another file in this repo being intact. The cost of
# that exemption is that the grammar has to be kept in step by hand, so:
#
#   <Subject>: <State>[ [rerouted-topic]]      e.g. "Backup: Failed [restic]"
#
# systemd/contract.sh checks this file by PATTERN rather than by constructor. See
# ntfy/MESSAGES.md § 5, nuance 12.
#
# THE SUCCESS BRANCH IS NOT DEAD CODE AND MUST NOT BE DELETED. Three units wire
# OnSuccess= here — restic.backup, restic.forget and restic.check@ — and those pings
# are the ONLY positive evidence that this path still reaches the phone. Nothing
# watches the courier: it inherits no OnFailure= (that would call the courier to
# complain about the courier) and carries no [X-Catallenya] Class, so the watchdog
# skips it too. Only the DAILY backup ping is frequent enough to serve as that canary;
# weekly, monthly and yearly are not. See ntfy/MESSAGES.md § 5, nuance 13.
# NO TAG AND NO PRIORITY, matching the shared transport by hand — which is the price
# of this file's exemption from it. Both were dropped repo-wide on 2026-08-20: priority
# had one legal value, and tags were twelve glyphs of which four meant "something is
# wrong". The title says which this is.
#
# THE OUTCOME COMES FROM THE INVOCATION, NOT THE UNIT'S CURRENT STATE (2026-08-24).
#
# `systemctl is-failed` answers "is this unit failed RIGHT NOW", which is a different
# question from "did the run that triggered me fail" — and they diverge exactly when
# it matters. A .path-driven job that fails is re-triggered immediately by its still-
# matching glob, so by the time the courier asks, the unit is `activating` again and
# is-failed says no. The alert then goes out titled Succeeded.
#
# Not hypothetical. On 2026-08-14 liquidroom.triage failed 203/EXEC thirteen times in
# about a second; seven alerts were destroyed by the rate limit (see the unit file)
# and the five that survived were all titled "Triage Success [liquidroom]". A false
# negative is worse than a dropped alert: the owner is not merely uninformed, they are
# actively told the thing is fine.
#
# systemd hands the real answer to an OnFailure=/OnSuccess= handler in MONITOR_*
# (systemd 249+; this box runs 255). Verified empirically with throwaway user units
# rather than taken from the docs, and the probe found the one constraint that
# matters: systemd REFUSES to populate these when a handler has more than one trigger
# source, logging "multiple trigger source candidates for exit status propagation,
# skipping" — and it counts OnSuccess= and OnFailure= pointing at the SAME instance as
# two. So the three restic jobs, which wire both, get nothing here.
#
# That is why the fallback stays rather than being an embarrassment: MONITOR_* covers
# every OnFailure-only job, which is every job that can hot-loop, while the restic trio
# that falls through is timer-driven and cannot re-trigger itself — so is-failed is
# reliable for precisely the units left using it.
outcome=""
case "${MONITOR_SERVICE_RESULT:-}" in
    success)  outcome="Succeeded" ;;
    "")       outcome="" ;;          # not passed — fall through to the state check
    *)        outcome="Failed" ;;    # exit-code, signal, timeout, oom-kill, …
esac
if [[ -z "$outcome" ]]; then
    if systemctl is-failed --quiet "${service_name}.service"; then
        outcome="Failed"
    else
        outcome="Succeeded"
    fi
fi
title="${job_type}: ${outcome}${routed_note}"

# Get systemctl status output
# THE BODY IS THE JOB'S OWN WORDS, not `systemctl status` (changed 2026-08-20).
#
# This one body serves every job failure in the fleet plus the four restic successes,
# and a status dump spent ~18 lines on Loaded=/Active=/Process= boilerplate before
# reaching anything a person wants. The useful sentence was in the journal excerpt at
# the bottom, if it fitted at all: restic.staleness prints exactly
#
#     Newest snapshot is 402h old, over the 48h limit (2026-07-15T00:31:02Z).
#
# and that arrived buried under systemd's own scaffolding. `-o cat` strips the
# timestamp and unit prefix, leaving the script's lines and systemd's own
# start/stop/result lines — which is the whole of what the notification is for.
#
# Nothing is lost: journalctl -u <unit> still holds the complete record, and the
# title already carries the outcome, so the exit code the dump provided is redundant.
#
# The fallback is not decoration. This is the alarm of last resort, and an EMPTY body
# would be worse than a verbose one — if the journal cannot be read (this runs as
# User=carrein, which is in `adm` today, but that is a property of the host rather
# than of this file) the status dump is still better than nothing.
# MONITOR_INVOCATION_ID first, for the same reason the title uses MONITOR_SERVICE_RESULT
# above: `systemctl show -p InvocationID` returns the invocation running NOW, and after
# a .path re-trigger that is the next run, not the one that just failed. The body would
# then quote a run that has barely started — usually nothing at all — while the failure
# it was sent about sat unreported in the previous invocation. Same divergence as the
# title, one line further down, and it would have been much harder to notice.
inv="${MONITOR_INVOCATION_ID:-}"
[[ -n "$inv" ]] || inv=$(systemctl show "${service_name}.service" -p InvocationID --value 2>/dev/null)
message=""
if [[ -n "$inv" ]]; then
    # THIS RUN ONLY, and only what the job PRINTED.
    #
    # _SYSTEMD_INVOCATION_ID scopes it to the invocation that just ended. Without it,
    # `-n 8` reaches back across runs: restic.staleness runs daily and prints one
    # line, so a failure arrived under five previous days of "within the 48h limit"
    # — the notification for a broken thing led with five reassurances.
    #
    # _TRANSPORT=stdout drops systemd's own Starting/Deactivated/Finished/Consumed/
    # Triggering lines, which otherwise fill the whole budget: `disk` prints nothing
    # when healthy, so every one of its eight lines was systemd talking about itself.
    message=$(journalctl "_SYSTEMD_INVOCATION_ID=${inv}" _TRANSPORT=stdout \
                  -n 8 --no-pager -o cat 2>/dev/null || true)
    # A job that printed nothing at all still has systemd's own verdict for this run,
    # and "Failed with result 'exit-code'" beats an empty notification.
    [[ -n "${message//[[:space:]]/}" ]] || \
        message=$(journalctl "_SYSTEMD_INVOCATION_ID=${inv}" -n 8 --no-pager -o cat 2>/dev/null || true)
fi
# Last resort. This is the alarm of last resort, and an EMPTY body would be worse
# than a verbose one — if the journal cannot be read at all (this runs as
# User=carrein, in `adm` today, but that is a property of the host rather than of
# this file) the old status dump is still better than nothing.
[[ -n "${message//[[:space:]]/}" ]] || message=$(systemctl status "${service_name}.service" || true)

# Same guard the intake libs and the heartbeat carry, placed immediately before
# the curl so everything up to the wire — ownership, topic routing, title and
# status derivation — is exercised by the offline suite without pinging the phone.
if [[ "${NTFY_DISABLE:-}" == "1" ]]; then
    echo "system-ntfy: NTFY_DISABLE=1, not publishing (${title} -> ${topic})"
    exit 0
fi

# -f: an HTTP-level error (5xx, a future auth failure) must exit non-zero, not
# swallow the alert with a 200-shaped success. systemd still reports a failed
# OnFailure= handler nowhere, but a failed courier at least shows in
# `systemctl --failed` instead of nowhere at all.
#
# --max-time: this runs as a FAILURE HANDLER, and an ntfy that accepts the connection
# and then stops answering would hold the handler open indefinitely — a systemd job
# stuck reporting a job that is already dead. TimeoutStartSec=2min on the unit is the
# outer bound; 15s is the same one the shared transport uses, chosen so three of these
# firing at once still finish inside it.
#
# --data-raw, never -d: curl reads a -d value beginning with "@" as a FILENAME and
# POSTs that file's contents. The body here is `systemctl status` output, which starts
# with a bullet today — but it is a machine-built string this script does not control,
# and the one difference between the two flags is that --data-raw can never be talked
# into reading a file.
curl -f --max-time 15 \
     -H "Title: $title" \
     --data-raw "$message" \
     "${NTFY_URL}/${topic}"