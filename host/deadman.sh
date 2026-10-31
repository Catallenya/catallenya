#!/bin/bash
# The off-box dead-man's switch.
#
# THIS IS THE ONE ALARM THAT DOES NOT LIVE ON THIS BOX. Everything else here —
# the heartbeat, the five gauges, the courier — dies with the machine, and a box
# that is dark reports nothing about being dark. The only shape that escapes that
# is inverted: something OUTSIDE is told to expect a signal on a schedule, and
# raises the alarm when the signal STOPS. Silence becomes the alert.
#
# WHY IT PINGS CONDITIONALLY, which is the whole design.
#
# An unconditional ping only ever proves the box has power. The gap actually worth
# closing is narrower and worse: ntfy is a container ON this box, so when it dies
# every alert in the fleet is dropped with no trace — a failing backup, a dying
# disk, a stopped watchdog all publish into nothing and every layer built to notice
# reports healthy. Nothing on this box can report that, because reporting it needs
# the thing that is broken.
#
# So the condition is exactly that question: CAN OUR ALERTS STILL GET OUT?
#
#   ntfy reachable      -> ping. healthchecks.io stays quiet, and any real problem
#                          reaches the phone through the normal channel.
#   ntfy unreachable    -> DO NOT PING. Three hours later healthchecks.io says the
#                          box has gone quiet, which is true in the only sense that
#                          matters: nothing this box says can reach you.
#
# THE WATCHING IS MUTUAL, and that is the answer to "who watches healthchecks.io".
# They watch us by our silence; we watch them by the ping's failure — a ping that
# does not return 2xx is reported through our own ntfy, which by then we have just
# proven works. Their own FAQ says multi-day outages are possible (one-person ops
# team), so this direction is not theoretical. Neither side is trusted to be up.
#
# Silent when healthy, like every other monitor here.
set -euo pipefail

# shellcheck disable=SC2034  # read by ntfy.lib.sh, sourced below
NTFY_TOPIC="host"

# A STABLE ID: this runs hourly and an unreachable ntfy persists, so without one a
# long outage would stack a notification an hour. Same arrangement as disk.sh.
DEADMAN_NTFY_ID="deadman"
# shellcheck source=/zpool/catallenya/ntfy/ntfy.lib.sh
source "/zpool/catallenya/ntfy/ntfy.lib.sh"

# Test seams, the same shape as SMARTCTL in smart.sh and DOCKER in containers.sh.
# Never set in production.
CURL="${CURL:-curl}"
PING_TIMEOUT="${PING_TIMEOUT:-15}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-10}"

# Where .env is. A seam, so the suite can hand this job a settings file with the
# ping URL missing and prove the not-armed branch below actually fires.
DEADMAN_ENV="${DEADMAN_ENV:-/zpool/catallenya/.env}"

# --- watching the watchdog ---------------------------------------------------
#
# The heartbeat is the one job nothing else checks, and CLAUDE.md claimed for a
# day that THIS script covered it. It did not: until 2026-08-24 the only mention
# of the heartbeat here was a comment. The gap is real and specific — if
# catallenya.heartbeat.timer stops, ntfy stays healthy, so this job keeps pinging,
# healthchecks.io stays green, and every "did that job actually run" finding simply
# stops being computed. Six of those jobs are silent when healthy, so a stopped
# restic, a stopped sanoid, a stopped disk gauge and a stopped SMART job all become
# indistinguishable from working ones. Nothing would ever say so.
#
# This is the right script for it precisely because it is a DIFFERENT unit on a
# DIFFERENT schedule: the heartbeat cannot be the thing that notices it has died.
#
# It NOTIFIES and still PINGS, deliberately. Refusing to ping would conflate two
# unrelated faults — this job's contract is "ping only while alerts can get out",
# and a stale heartbeat is not an alert-channel failure. ntfy has just been proven
# working three lines above, so the box can report this itself; spending the
# external alarm on it would make silence mean two things at once.
HEARTBEAT_STAMP="${HEARTBEAT_STAMP:-/zpool/catallenya/systemd/state/catallenya.heartbeat}"
# MUST NOT be shorter than the heartbeat's own MaxAge, or this fires on a job that
# the watchdog itself still considers fresh. The two are held equal by a case in
# host/tests/run.sh that parses the sticker out of the unit and compares — the same
# joint as the healthchecks.io cadence, but this one is checkable, so it is checked.
HEARTBEAT_MAX_AGE="${HEARTBEAT_MAX_AGE:-36h}"
HEARTBEAT_NTFY_ID="deadman-watchdog"

# The ntfy trio, for the health probe below. This is the transport's own loader:
# it extracts named keys one at a time rather than sourcing, which is what keeps
# forty credentials and any stray $(...) out of this process.
if ! _ntfy_env; then
    echo "deadman: cannot read the ntfy settings from .env" >&2
    exit 1
fi

# The ping URL is read HERE rather than through _ntfy_env's extra-keys argument,
# for two reasons. It is not an ntfy setting and has no business arriving through
# the notification transport's loader; and that loader's path is fixed by design,
# which would leave the not-armed branch below untestable. Same extract-don't-source
# shape, same reasoning, written out locally exactly as changedetection.health.sh
# does for its one extra key.
#
# It is a SECRET. Anyone holding it can ping on our behalf, which would keep
# healthchecks.io quiet while the box is dead — the failure this job exists to
# prevent, handed to a stranger. So: .env only, never this file, never git, and
# never a notification body.
HEALTHCHECKS_PING_URL=""
if [[ -f "$DEADMAN_ENV" ]]; then
    line="$(grep -m1 '^HEALTHCHECKS_PING_URL=' "$DEADMAN_ENV" 2>/dev/null)" || true
    HEALTHCHECKS_PING_URL="${line#*=}"
    HEALTHCHECKS_PING_URL="${HEALTHCHECKS_PING_URL%\"}"
    HEALTHCHECKS_PING_URL="${HEALTHCHECKS_PING_URL#\"}"
fi

if [[ -z "${HEALTHCHECKS_PING_URL:-}" ]]; then
    # A SWITCH THAT IS NOT CONFIGURED MUST NOT LOOK HEALTHY. Exiting 0 here would
    # leave a job that runs daily, reports success, stamps itself fresh for the
    # watchdog and pings nothing — so healthchecks.io would alarm three hours in
    # and the box would insist everything was fine. Fail instead.
    echo "deadman: HEALTHCHECKS_PING_URL is not set in ${DEADMAN_ENV} — the switch is not armed" >&2
    exit 1
fi

# --- can our alerts still get out? -------------------------------------------
# Probed through the REAL DELIVERY PATH — the tailnet hostname and the Caddy port
# that notify() itself publishes to — rather than against the ntfy container
# directly. A container that is up behind a Caddy that is down delivers nothing,
# and it is delivery this job is asking about, not liveness. This therefore covers
# the tailscale sidecar, Caddy and ntfy in one question.
#
# /v1/health is ntfy's own endpoint and returns {"healthy":true}. The BODY is
# checked, not just the status: ntfy answers 200 while reporting itself unhealthy,
# so trusting the code alone would read a self-declared fault as success.
NTFY_HEALTH_URL="https://${TAILNET_DOMAIN}.${TAILNET_DNS_NAME}:${NTFY_REVERSE_PROXY_PORT}/v1/health"

health_rc=0
health_body="$("$CURL" -fsS --max-time "$HEALTH_TIMEOUT" "$NTFY_HEALTH_URL" 2>&1)" || health_rc=$?

if (( health_rc != 0 )) || [[ "$health_body" != *'"healthy":true'* ]]; then
    # DO NOT PING. This is the branch the whole job exists for, and the correct
    # behaviour is to do nothing and say so loudly in the journal — the phone
    # cannot be reached, by definition, or we would not be here.
    #
    # It exits non-zero so ExecStartPost= writes no stamp: the watchdog then also
    # reports this job, which is a second independent path to the same truth for
    # whenever ntfy comes back. The inherited OnFailure= will try the courier and
    # fail too; harmless, and the journal carries both.
    echo "deadman: ntfy is NOT reachable at ${NTFY_HEALTH_URL}" >&2
    if (( health_rc != 0 )); then
        echo "deadman:   curl said: ${health_body}" >&2
    else
        echo "deadman:   it answered, but not healthy: ${health_body}" >&2
    fi
    echo "deadman:   DELIBERATELY NOT PINGING healthchecks.io — every alert on this box" >&2
    echo "deadman:   is being dropped, so external silence is the only honest signal" >&2
    echo "deadman:   expect a healthchecks.io alert once the grace window elapses" >&2
    exit 1
fi

# --- ping --------------------------------------------------------------------
# `-f` so an HTTP error is a failure rather than a body we ignore, and --retry for
# a blip: a single lost packet must not spend an hour of the grace window. --max-time
# is per attempt, so the worst case is bounded well inside the monitor class's
# 10-minute TimeoutStartSec.
ping_rc=0
ping_out="$("$CURL" -fsS --max-time "$PING_TIMEOUT" --retry 2 --retry-delay 5 \
                   "$HEALTHCHECKS_PING_URL" 2>&1)" || ping_rc=$?

if (( ping_rc != 0 )); then
    # THE OTHER HALF OF THE MUTUAL WATCH. We have just proven ntfy works, so this
    # is reportable — and it is worth reporting, because from here on the box is
    # unwatched from outside and nothing else would ever say so. healthchecks.io
    # will also alarm on our silence, but that message goes to whatever address is
    # on their side and assumes they are the ones still working.
    #
    # The URL is deliberately NOT in the body: it is a secret, and a notification
    # is the least private place on this box.
    body="$(body_join \
        "$(body_fact "The last ping was refused after 3 attempts" \
                     "Nothing outside this box is watching it until this clears")" \
        "curl said: $(md_escape "${ping_out:-no output}")")"
    echo "deadman: healthchecks.io ping FAILED: ${ping_out}" >&2
    out="$(notify_fault "$(title_state "Dead Man's Switch" "Unreachable")" "$body" "$DEADMAN_NTFY_ID" 2>&1)"
    if [[ -n "$out" ]]; then
        echo "deadman: and the ntfy alert about it also failed: ${out}" >&2
    fi
    exit 1
fi

# --- is the watchdog still running? ------------------------------------------
#
# Reached only once the ping has succeeded, so this never delays the job's primary
# duty. Exits 0 either way: this is a REPORTER finding in the sense CLAUDE.md uses
# — the bad news is about another job, not about this one — so failing here would
# skip our own ExecStartPost stamp and report THIS job stale for a fault that
# belongs to the heartbeat. The notification is the signal.
hb_age=-1
if [[ -e "$HEARTBEAT_STAMP" ]]; then
    hb_age=$(( $(date +%s) - $(stat -c %Y "$HEARTBEAT_STAMP") ))
fi
hb_max=$(systemd-analyze timespan "$HEARTBEAT_MAX_AGE" 2>/dev/null | awk 'NR==2 {print $NF}')
[[ "$hb_max" =~ ^[0-9]+$ ]] && hb_max=$(( hb_max / 1000000 )) || hb_max=129600   # 36h

if (( hb_age < 0 )); then
    hb_body="$(body_join \
        "$(body_fact "The watchdog has no completion stamp" \
                     "Expected at ${HEARTBEAT_STAMP}")" \
        "Nothing is checking whether the other jobs still run. A stopped restic, sanoid, disk or SMART job would look exactly like a healthy one.")"
    echo "deadman: heartbeat stamp missing at ${HEARTBEAT_STAMP}" >&2
    out="$(fault_open "$HEARTBEAT_NTFY_ID" "$(title_state "Watchdog" "Stalled")" "$hb_body" 2>&1)"
    [[ -n "$out" ]] && echo "deadman: and the ntfy alert about it also failed: ${out}" >&2
elif (( hb_age > hb_max )); then
    hb_body="$(body_join \
        "$(body_fact "The watchdog last completed $(( hb_age / 3600 ))h ago" \
                     "Its own limit is ${HEARTBEAT_MAX_AGE}")" \
        "Nothing is checking whether the other jobs still run. A stopped restic, sanoid, disk or SMART job would look exactly like a healthy one.")"
    echo "deadman: heartbeat is stale — $(( hb_age / 3600 ))h against ${HEARTBEAT_MAX_AGE}" >&2
    out="$(fault_open "$HEARTBEAT_NTFY_ID" "$(title_state "Watchdog" "Stalled")" "$hb_body" 2>&1)"
    [[ -n "$out" ]] && echo "deadman: and the ntfy alert about it also failed: ${out}" >&2
else
    # The watchdog is running again: a "Watchdog: Stalled" sent earlier becomes
    # "Watchdog: Running" (ntfy.lib.sh fault_close, the recovery rule). No marker, no message.
    out="$(fault_close "$HEARTBEAT_NTFY_ID" Running "The daily roll call is completing again." 2>&1)"
    [[ -n "$out" ]] && echo "deadman: the watchdog recovery notification failed: ${out}" >&2
fi

# Silence is the healthy state. The ping IS the output.
#
# EXPLICIT, and not decoration. Without it the exit status is whatever the last
# command left behind — and in the watchdog branches above that is
# `[[ -n "$out" ]]`, which is FALSE whenever the notification succeeded, so a
# perfectly good run reported failure. Caught by the suite the same hour it was
# written; it is the same shape as every other wrong-result-behind-a-right-exit-code
# bug in this repo, only inverted.
exit 0
