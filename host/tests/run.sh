#!/usr/bin/env bash
# Regression tests for the host monitors.
#
# Everything here runs OFFLINE: NTFY_DISABLE=1 suppresses the wire, and `docker` is a
# stub replaying captured output, so no case touches the daemon or the fleet.
#
# WHY THIS TREE EXISTS NOW. It deliberately did not on 2026-08-22, when smart.sh
# shipped — one hand-rolled parser was judged not worth new infrastructure, and its
# note said so while flagging that "a hand-rolled parser with no test is exactly the
# fragile thing". containers.sh is the second, with more branches than the first, and
# two is where the infrastructure pays for itself. smart.sh already has the matching
# SMARTCTL seam, so it can join without changing that script.
#
# EVERY CASE HERE IS A BRANCH THAT DECIDES WHETHER AN ALERT HAPPENS. A monitor that
# silently reports "all clear" is worse than no monitor, so the cases that assert
# SILENCE matter as much as the ones that assert a message.
#
#   bash host/tests/run.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${SELF_DIR}/../.." && pwd)"
export NTFY_DISABLE=1

PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
is()   { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "$3" "$2"; }
has()  { [[ "$2" == *"$3"* ]] && ok "$1" || bad "$1" "contains: $3" "$2"; }
hasnt(){ [[ "$2" != *"$3"* ]] && ok "$1" || bad "$1" "must not contain: $3" "$2"; }

TMP="$(mktemp -d)"
# Recovery markers (ntfy.lib.sh fault_open/fault_close) go to scratch. NOT optional: the
# undelivered-alert case below turns NTFY_DISABLE off, and with no seam fault_open then
# writes the LIVE systemd/state/.faults — on 2026-10-31 that left a fake "ntfy: Exited"
# which the next real hourly run would have "recovered" on the phone.
export NTFY_FAULT_DIR="${TMP}/faults"
trap 'rm -rf "$TMP"' EXIT

# --- the docker stub ---------------------------------------------------------
# Replays whatever the current fixture directory holds. Three subcommands, matching
# the three containers.sh makes. `inspect.2`, when present, is served to the SECOND
# inspect of a run — which is how the re-probe's confirm-twice rule is tested.
cat > "${TMP}/docker" <<'STUB'
#!/usr/bin/env bash
F="$FIXTURE"
case "$1" in
  compose)
    [[ -f "${F}/services.rc" ]] && { cat "${F}/services" 2>/dev/null; exit "$(<"${F}/services.rc")"; }
    cat "${F}/services" ;;
  ps)
    [[ -f "${F}/ps.rc" ]] && { cat "${F}/ps" 2>/dev/null; exit "$(<"${F}/ps.rc")"; }
    cat "${F}/ps" ;;
  inspect)
    n=0
    [[ -f "${F}/.n" ]] && n="$(<"${F}/.n")"
    n=$((n+1)); printf '%s' "$n" > "${F}/.n"
    if (( n >= 2 )) && [[ -f "${F}/inspect.2" ]]; then cat "${F}/inspect.2"; else cat "${F}/inspect"; fi ;;
esac
STUB
chmod +x "${TMP}/docker"

# fixture <name> — start a fresh fixture directory holding the HEALTHY fleet.
# Every case begins from health and mutates one thing, so a case can only fail for
# its own reason. (The systemd suite learned this the hard way: it reset only the
# unit each case touched, mutations accumulated, and two adversarial cases were
# passing on a neighbour's error message rather than their own.)
FIXTURE=""
fixture() {
    FIXTURE="${TMP}/$1"
    mkdir -p "$FIXTURE"
    printf '%s\n' caddy ntfy radicale immich-server postgres > "${FIXTURE}/services"
    printf '%s\n' caddy ntfy radicale immich-server immich-postgres > "${FIXTURE}/ps"
    cat > "${FIXTURE}/inspect" <<'INS'
caddy|/caddy|running|healthy|0|2026-08-22T10:00:00.000000000Z
ntfy|/ntfy|running|none|0|2026-08-22T10:00:00.000000000Z
radicale|/radicale|running|healthy|0|2026-08-22T10:00:00.000000000Z
immich-server|/immich-server|running|healthy|0|2026-08-22T10:00:00.000000000Z
postgres|/immich-postgres|running|healthy|0|2026-08-22T10:00:00.000000000Z
INS
    export FIXTURE
}

# run [state-file] — execute containers.sh against the current fixture.
# Sets OUT (stdout+stderr) and RC, as GLOBALS, and is therefore called bare rather
# than through $( ).
#
# It used to `printf` its output and be called as out="$(run)", which put the whole
# function in a SUBSHELL — so `RC=$?` was assigned in a process that then exited and
# every exit-code assertion read whatever RC happened to hold from an earlier case.
# Two of them could not fail. This is the same trap containers.sh carries a comment
# about for its own probe(), found here by a deadman case that asserted 0 while RC
# still held a 1 from the case above it.
RC=0
OUT=""
run() {
    local state="${1:-${TMP}/state-$$-${RANDOM}}"
    RC=0
    PATH="${TMP}:${PATH}" DOCKER="${TMP}/docker" \
        CONTAINERS_STATE="$state" \
        CONTAINERS_COMPOSE="${FIXTURE}/compose.yml" \
        RECHECK_SECONDS=0 \
        bash "${REPO}/host/containers.sh" > "${TMP}/out" 2>&1 || RC=$?
    OUT="$(<"${TMP}/out")"
}

# A run whose state file already remembers the healthy fleet, so restart deltas and
# the no-longer-declared check are armed. A first run has no memory and is silent on
# both by design.
seed_state() {
    cat > "$1" <<'ST'
caddy	0
ntfy	0
radicale	0
immich-server	0
postgres	0
ST
}

# ---------------------------------------------------------------- healthy fleet
echo "healthy fleet"
fixture healthy
run; out="$OUT"
is    "silent when everything is up"  "$out" ""
is    "and exits 0"                   "$RC"  "0"

echo "state file"
fixture state
st="${TMP}/state-written"
run "$st"
is    "remembers every expected service" "$(wc -l < "$st")" "5"
has   "with its restart counter"         "$(cat "$st")" $'caddy\t0'
# A service key, not a container name: `postgres` runs as `immich-postgres`, and
# remembering the container name would break the lookup on the next run.
has   "keyed by compose service"         "$(cat "$st")" "postgres"
hasnt "not by container name"            "$(cat "$st")" "immich-postgres"

# ------------------------------------------------------------------- not running
echo "a container that is not running"
fixture stopped
sed -i 's|^radicale|/radicale|; s|/radicale|radicale|' "${FIXTURE}/inspect"
sed -i 's|^radicale|/radicale|' /dev/null 2>/dev/null || true
perl -pi -e 's{^radicale\|/radicale\|running}{radicale|/radicale|exited}' "${FIXTURE}/inspect"
run; out="$OUT"
has   "names the container in the title" "$out" "radicale: Exited"
has   "says what state it is in"         "$out" "the container is exited, not running"
is    "and exits 0 — it reported"        "$RC" "0"
# The healthy count is a FACT, and it must exclude the dead one or the number lies.
has   "counts only what is up"           "$out" "4 of 5 expected containers running"

# ----------------------------------------------------------------------- missing
echo "a service with no container at all"
fixture missing
# Declared in compose, absent from `ps` and from `inspect`. This is the case a check
# built on `docker ps` alone cannot see — a half-finished compose down, or a
# watchtower update that removed the old container and never created the new one.
perl -ni -e 'print unless /^ntfy/' "${FIXTURE}/ps" "${FIXTURE}/inspect"
run; out="$OUT"
has   "reported as Missing"        "$out" "ntfy: Missing"
has   "and says why that is bad"   "$out" "declared in compose but no container exists"

# --------------------------------------------------------------------- unhealthy
echo "a container failing its own healthcheck"
fixture unhealthy
perl -pi -e 's{^caddy\|/caddy\|running\|healthy}{caddy|/caddy|running|unhealthy}' "${FIXTURE}/inspect"
run; out="$OUT"
has   "reported as Unhealthy"       "$out" "caddy: Unhealthy"
has   "and notes it is still up"    "$out" "running, but its own healthcheck is failing"

# ---------------------------------------------------------- healthcheck never passes
echo "a healthcheck that never passes"
fixture starting
# `starting` an hour after launch is a healthcheck that will never pass, and it reads
# as healthy to anything that only asks whether the container is running.
old="$(date -u -d '90 minutes ago' +%Y-%m-%dT%H:%M:%S.000000000Z)"
perl -pi -e "s{^caddy\\|/caddy\\|running\\|healthy\\|0\\|.*}{caddy|/caddy|running|starting|0|${old}}" "${FIXTURE}/inspect"
run; out="$OUT"
has   "reported as Never Healthy"  "$out" "caddy: Never Healthy"
has   "with how long it has been"  "$out" "after launch, so its healthcheck has never passed"

echo "a healthcheck still inside its grace window"
fixture starting_ok
fresh="$(date -u -d '1 minute ago' +%Y-%m-%dT%H:%M:%S.000000000Z)"
perl -pi -e "s{^caddy\\|/caddy\\|running\\|healthy\\|0\\|.*}{caddy|/caddy|running|starting|0|${fresh}}" "${FIXTURE}/inspect"
run; out="$OUT"
is    "stays silent while warming up" "$out" ""

# ----------------------------------------------------------------- restart looping
echo "restart looping"
fixture looping
perl -pi -e 's{^ntfy\|/ntfy\|running\|none\|0}{ntfy|/ntfy|running|none|7}' "${FIXTURE}/inspect"
st="${TMP}/state-loop"; seed_state "$st"
run "$st"; out="$OUT"
has   "reported as Restart Looping" "$out" "ntfy: Restart Looping"
has   "with the delta, not the total" "$out" "restarted 7 times since the last check"

echo "a single restart is a blip, not a loop"
fixture blip
perl -pi -e 's{^ntfy\|/ntfy\|running\|none\|0}{ntfy|/ntfy|running|none|1}' "${FIXTURE}/inspect"
st="${TMP}/state-blip"; seed_state "$st"
run "$st"; out="$OUT"
is    "stays silent"  "$out" ""

echo "a first run has no memory and cannot judge restarts"
fixture firstrun
perl -pi -e 's{^ntfy\|/ntfy\|running\|none\|0}{ntfy|/ntfy|running|none|9}' "${FIXTURE}/inspect"
run; out="$OUT"
# 9 restarts with no baseline could be nine crashes or a container created months ago.
# Reporting it would page on every fresh deploy.
is    "silent without a baseline" "$out" ""

# ------------------------------------------------------- a service left the compose file
echo "a service that is no longer declared"
fixture undeclared
perl -ni -e 'print unless /^radicale$/' "${FIXTURE}/services"
perl -ni -e 'print unless /^radicale/' "${FIXTURE}/ps" "${FIXTURE}/inspect"
st="${TMP}/state-undeclared"; seed_state "$st"
run "$st"; out="$OUT"
has   "reported once"  "$out" "radicale: No Longer Declared"
# This is the guard against a broken compose edit silently NARROWING what is watched
# — the fleet would shrink and the check would still say all clear.
has   "and says what changed" "$out" "was expected last run and is not in the compose file now"
run "$st"; out2="$OUT"
is    "and not again on the next run" "$out2" ""

# ------------------------------------------- a PROFILED service is never remembered
# The regression that produced three false alerts on 2026-08-28. A profiled service
# is invisible to `compose config --services` on purpose — the profile is what marks
# it as allowed to be absent — but it IS visible to `docker ps` while it runs. So a
# liquidroom job that started one, finished, and let `--rm` take it away left the
# service in the state file, and the next hourly pass reported it as having left the
# compose file. Once per music request, indefinitely.
echo "a profiled service that runs transiently is not remembered"
fixture profiled
# Present in ps/inspect (it is running right now) but absent from services (no profile).
printf 'liquidroom-roformer|/liquidroom-job|running|none|0|2026-08-28T15:51:03Z\n' \
    >> "${FIXTURE}/inspect"
printf 'liquidroom-job\n' >> "${FIXTURE}/ps"
st="${TMP}/state-profiled"
run "$st"; out="$OUT"
hasnt "the running profiled service is not itself a finding" "$out" "liquidroom-roformer"
hasnt "and it never enters the state file" "$(cat "$st" 2>/dev/null)" "liquidroom-roformer"
# ...so when the job ends and the container goes, there is nothing to miss.
perl -ni -e 'print unless /^liquidroom/' "${FIXTURE}/inspect" "${FIXTURE}/ps"
run "$st"; out2="$OUT"
hasnt "and its disappearance is silent" "$out2" "No Longer Declared"
is    "which means the run is clean"    "$out2" ""

# --------------------------------------------------------------- docker unreachable
echo "the docker daemon is unreachable"
fixture nodocker
printf '%s\n' "Cannot connect to the Docker daemon at unix:///var/run/docker.sock." > "${FIXTURE}/ps"
printf '1' > "${FIXTURE}/ps.rc"
st="${TMP}/state-nodocker"; seed_state "$st"
run "$st"; out="$OUT"
has   "reported as Not Responding" "$out" "Docker: Not Responding"
has   "carrying the daemon's words" "$out" "Cannot connect to the Docker daemon"
# The remembered counters must SURVIVE an outage. Overwriting them with nothing would
# disarm restart-loop detection for a run every time docker hiccups.
is    "state file left untouched"   "$(wc -l < "$st")" "5"

echo "the compose file cannot be read"
fixture nocompose
printf '%s\n' "no configuration file provided: not found" > "${FIXTURE}/services"
printf '1' > "${FIXTURE}/services.rc"
run; out="$OUT"
has   "reported as Unreadable"  "$out" "Compose: Unreadable"
has   "and names the file"      "$out" "cannot list services"

echo "compose returns an empty service list"
fixture emptycompose
: > "${FIXTURE}/services"
run; out="$OUT"
# Zero services is byte-identical to a clean bill of health if it is not caught: the
# loop never runs, nothing is found, and the check reports all clear forever. Same
# door as changedetection.health's empty watch list.
has   "empty is a finding, not silence" "$out" "Compose: Unreadable"

# ------------------------------------------------------------------------- titles
echo "titles"
fixture onefinding
perl -pi -e 's{^ntfy\|/ntfy\|running\|none\|0}{ntfy|/ntfy|exited|none|0}' "${FIXTURE}/inspect"
run; out="$OUT"
# One finding names the container, which is the most useful thing a lock screen can
# carry. The subject is narrower than the `host` topic, as the contract requires.
has   "one finding names the container" "$out" "ntfy: Exited"
hasnt "and is not a count"              "$out" "Containers: 1 Finding"

fixture twofindings
perl -pi -e 's{^ntfy\|/ntfy\|running\|none\|0}{ntfy|/ntfy|exited|none|0}' "${FIXTURE}/inspect"
perl -pi -e 's{^caddy\|/caddy\|running\|healthy}{caddy|/caddy|running|unhealthy}' "${FIXTURE}/inspect"
run; out="$OUT"
has   "two findings become a count"  "$out" "Containers: 2 Findings"
has   "and both are listed"          "$out" "ntfy"
has   "with the second one too"      "$out" "caddy"

# --------------------------------------------------------------- the confirm rule
echo "the re-probe"
fixture flap
# Present in the first pass, gone in the second — exactly the shape watchtower's
# recreate window produces. An alert here would cry wolf on every image update, and a
# monitor that cries wolf trains you to ignore the topic that also carries a dead ntfy.
perl -pi -e 's{^caddy\|/caddy\|running\|healthy}{caddy|/caddy|restarting|healthy}' "${FIXTURE}/inspect"
cp "${FIXTURE}/inspect" "${FIXTURE}/inspect.2"
perl -pi -e 's{^caddy\|/caddy\|restarting\|healthy}{caddy|/caddy|running|healthy}' "${FIXTURE}/inspect.2"
run; out="$OUT"
is    "a finding seen once is dropped" "$out" ""

fixture persists
perl -pi -e 's{^caddy\|/caddy\|running\|healthy}{caddy|/caddy|restarting|healthy}' "${FIXTURE}/inspect"
cp "${FIXTURE}/inspect" "${FIXTURE}/inspect.2"
run; out="$OUT"
has   "a finding seen twice is sent" "$out" "caddy: Restarting"

# ---------------------------------------------------------------- dropped alert
echo "a dropped alert fails the unit"
fixture dropped
perl -pi -e 's{^ntfy\|/ntfy\|running\|none\|0}{ntfy|/ntfy|exited|none|0}' "${FIXTURE}/inspect"
# NTFY_DISABLE off, and a curl on PATH that fails the way a 5xx or a dead host does.
# The transport is best-effort by contract, so its SILENCE is the test — anything it
# prints is an undelivered alert. Without this branch an ntfy outage would leave an
# hour indistinguishable from a healthy one while ExecStartPost= stamped the run
# fresh: a watcher whose failure reads as health.
cat > "${TMP}/curl" <<'CURL'
#!/usr/bin/env bash
echo "curl: (7) Failed to connect" >&2
exit 7
CURL
chmod +x "${TMP}/curl"
RC=0
out="$(PATH="${TMP}:${PATH}" DOCKER="${TMP}/docker" NTFY_DISABLE="" \
       CONTAINERS_STATE="${TMP}/state-dropped" CONTAINERS_COMPOSE="${FIXTURE}/compose.yml" \
       RECHECK_SECONDS=0 bash "${REPO}/host/containers.sh" 2>&1)" || RC=$?
is    "the unit fails"                "$RC" "1"
has   "and says the alert was lost"   "$out" "ntfy publish FAILED"
has   "with the findings still logged" "$out" "ntfy: Exited"
rm -f "${TMP}/curl"

# =================================================================== disk.sh
# The three-filesystem gauge. It had NO test at all until 2026-08-24, which is why
# the /boot gap below went unnoticed: nothing exercised it, so nothing could notice
# what it did not look at.
#
# Driven through PATH stubs for df, zpool and findmnt, with NTFY_DISABLE muting the
# wire — so threshold arithmetic, the mountpoint guard and body construction all run
# for real.
echo
echo "disk: the gauge"

DK="${TMP}/dk"; mkdir -p "${DK}/bin"
cat > "${DK}/bin/df" <<'DKS'
#!/usr/bin/env bash
tgt="${@: -1}"
case "$tgt" in
  /boot) printf 'Used Size Avail Use%%\n%s\n' "${DK_BOOT:-311M 2.0G 1.5G 18%}" ;;
  *)     printf 'Used Size Avail Use%%\n%s\n' "${DK_ROOT:-84G 455G 348G 20%}" ;;
esac
DKS
cat > "${DK}/bin/zpool" <<'DKS'
#!/usr/bin/env bash
printf '%s\n' "${DK_ZPOOL:-48%	3.48T	1.67T	1.81T}"
DKS
cat > "${DK}/bin/findmnt" <<'DKS'
#!/usr/bin/env bash
[[ "${DK_BOOT_MOUNT:-yes}" == "yes" ]] && echo /boot
exit 0
DKS
chmod +x "${DK}/bin"/*

# The DK_* knobs are set by each caller as a command prefix (`DK_BOOT=… dk_run`),
# which bash exports for the duration of the call — so they reach the stubs without
# being restated here. Restating them was worse than redundant: re-assigning DK in a
# prefix that also expands ${DK} is SC2097/SC2098, and the expansion silently reads
# the OUTER value rather than the one being assigned.
dk_run() {
    RC=0
    OUT="$(PATH="${DK}/bin:$PATH" NTFY_DISABLE=1 bash "${REPO}/host/disk.sh" 2>&1)" || RC=$?
}

echo "  everything healthy"
DK_BOOT="" DK_ROOT="" DK_ZPOOL="" dk_run
is "silent"  "$OUT" ""
is "exits 0" "$RC" "0"

echo "  /boot over threshold"
DK_BOOT="1.6G 2.0G 400M 80%" dk_run
has "it is reported"                    "$OUT" "boot at 80%"
has "and names the real consequence"    "$OUT" "remote LUKS unlock"
has "and points at the likely cause"    "$OUT" "autoremove"

echo "  /boot just under threshold"
DK_BOOT="1.4G 2.0G 600M 74%" dk_run
is "silent at 74%" "$OUT" ""

# THE GUARD. Where /boot is a plain directory rather than its own partition, `df
# /boot` returns the ROOT filesystem — so without this the same disk is reported
# twice under two names, with two stable ids, whenever root crosses. A reader then
# has two notifications and no way to tell they are one problem.
echo "  /boot is not a separate mount"
DK_BOOT_MOUNT="no" DK_ROOT="400G 455G 20G 88%" dk_run
has  "root is still reported"                "$OUT" "root at 88%"
hasnt "but /boot is not reported at all"     "$OUT" "boot at"

echo "  root and /boot both over"
DK_BOOT_MOUNT="yes" DK_ROOT="400G 455G 20G 88%" DK_BOOT="1.6G 2.0G 400M 80%" dk_run
has "root is reported"           "$OUT" "root at 88%"
has "and /boot separately"       "$OUT" "boot at 80%"

unset DK_BOOT DK_ROOT DK_ZPOOL DK_BOOT_MOUNT

# =============================================================== deadman.sh
# The off-box dead man's switch. Its ONE job is to be silent at the right moments:
# it must ping while alerts can get out, and it must REFUSE to ping when they
# cannot. A version that pings unconditionally passes every naive test and closes
# none of the gap, so the case that matters most below is a negative one.
echo
echo "deadman: the switch"

# A curl stub. Records every URL it is asked for, so a test can assert that
# hc-ping.com was NOT contacted — which is the whole point of the job.
DM="${TMP}/dm"; mkdir -p "$DM"
cat > "${TMP}/dmcurl" <<'DMC'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in http*) url="$a";; esac; done
printf '%s\n' "$url" >> "${DM_LOG}"
case "$url" in
  *hc-ping.com*)
    [[ -f "${DM}/ping.rc" ]] && { echo "curl: (22) The requested URL returned error: 500" >&2; exit "$(<"${DM}/ping.rc")"; }
    exit 0 ;;
  *v1/health*)
    [[ -f "${DM}/health.rc" ]] && { echo "curl: (7) Failed to connect" >&2; exit "$(<"${DM}/health.rc")"; }
    cat "${DM}/health.body" 2>/dev/null || echo '{"healthy":true}'
    exit 0 ;;
esac
exit 0
DMC
chmod +x "${TMP}/dmcurl"

dm_reset() {
    rm -f "${DM}/ping.rc" "${DM}/health.rc" "${DM}/health.body"; : > "${TMP}/dmlog"
    # A stamp this run considers FRESH. Pointing the default at the real stamp would
    # make every case above depend on when the watchdog last ran — green today, red
    # the first morning the heartbeat is late, for reasons having nothing to do with
    # the case under test.
    HB_STAMP="${DM}/hb"; : > "$HB_STAMP"
}

# Sets OUT and RC as globals, for the subshell reason documented on run() above.
dm_run() {
    RC=0
    DM="$DM" DM_LOG="${TMP}/dmlog" CURL="${TMP}/dmcurl" DEADMAN_ENV="${1:-${REPO}/.env}" \
    HEARTBEAT_STAMP="$HB_STAMP" \
        bash "${REPO}/host/deadman.sh" > "${TMP}/dmout" 2>&1 || RC=$?
    OUT="$(<"${TMP}/dmout")"
}

dm_pinged() { grep -q 'hc-ping.com' "${TMP}/dmlog"; }

echo "  ntfy healthy"
dm_reset; dm_run; out="$OUT"
is    "silent"                  "$out" ""
is    "exits 0"                 "$RC" "0"
dm_pinged && ok "and it pinged" || bad "and it pinged" "a call to hc-ping.com" "none"

echo "  ntfy unreachable"
dm_reset; printf '7' > "${DM}/health.rc"; dm_run; out="$OUT"
is    "exits 1"                       "$RC" "1"
has   "says ntfy is not reachable"    "$out" "ntfy is NOT reachable"
has   "and says why it is not pinging" "$out" "DELIBERATELY NOT PINGING"
# THE CASE THE WHOLE JOB EXISTS FOR. Pinging here would tell healthchecks.io that
# everything is fine at the exact moment every alert on this box is being dropped —
# a watcher actively certifying the failure it was built to catch.
dm_pinged && bad "and it did NOT ping" "no call to hc-ping.com" "it pinged anyway" || ok "and it did NOT ping"

echo "  ntfy answers 200 but reports itself unhealthy"
dm_reset; printf '%s' '{"healthy":false}' > "${DM}/health.body"; dm_run; out="$OUT"
# Checking the status code alone would read a self-declared fault as success.
is    "exits 1"                    "$RC" "1"
has   "quotes what it answered"    "$out" '"healthy":false'
dm_pinged && bad "and it did NOT ping" "no call to hc-ping.com" "it pinged anyway" || ok "and it did NOT ping"

echo "  the ping itself fails"
dm_reset; printf '22' > "${DM}/ping.rc"; dm_run; out="$OUT"
# The other half of the mutual watch: ntfy has just been proven reachable, so THIS
# is reportable, and it is the only thing that would ever tell you the outside
# watcher has stopped watching.
is    "exits 1"                        "$RC" "1"
has   "reports the failed ping"        "$out" "ping FAILED"
hasnt "and never prints the secret URL" "$out" "hc-ping.com/"

echo "  not armed"
dm_reset
grep -v '^HEALTHCHECKS_PING_URL=' "${REPO}/.env" > "${TMP}/env-unarmed" 2>/dev/null || : > "${TMP}/env-unarmed"
dm_run "${TMP}/env-unarmed"; out="$OUT"
# A switch that is not configured must not look healthy: exiting 0 would stamp the
# run fresh for the watchdog while healthchecks.io alarmed three hours later, and
# the box would insist everything was fine.
is    "exits 1"                  "$RC" "1"
has   "says it is not armed"     "$out" "the switch is not armed"
dm_pinged && bad "and it did NOT ping" "no call to hc-ping.com" "it pinged anyway" || ok "and it did NOT ping"

# --- watching the watchdog ---------------------------------------------------
# The heartbeat is the only job nothing else checks, and CLAUDE.md asserted for a
# day that this script covered it while the sole mention here was a comment. These
# cases exist so that claim is true and stays true.
#
# The one that matters is the SECOND assertion in each pair: it must still ping. A
# stale watchdog is not an alert-channel failure, and spending the external alarm
# on it would make silence mean two different things — the exact ambiguity the
# whole inverted design exists to avoid.
echo "  the watchdog has gone stale"
dm_reset; touch -d '40 hours ago' "$HB_STAMP"; dm_run; out="$OUT"
is    "exits 0 — this is a reporter finding, not its own failure" "$RC" "0"
has   "says the watchdog is stale"   "$out" "heartbeat is stale"
has   "and quotes the age"           "$out" "40h"
dm_pinged && ok "and it STILL pinged" || bad "and it STILL pinged" "a call to hc-ping.com" "none"

echo "  the watchdog has never run"
dm_reset; rm -f "$HB_STAMP"; dm_run; out="$OUT"
is    "exits 0"                      "$RC" "0"
has   "says the stamp is missing"    "$out" "heartbeat stamp missing"
dm_pinged && ok "and it STILL pinged" || bad "and it STILL pinged" "a call to hc-ping.com" "none"

echo "  the watchdog is fresh"
dm_reset; touch -d '2 hours ago' "$HB_STAMP"; dm_run; out="$OUT"
is    "silent"                       "$out" ""
is    "exits 0"                      "$RC" "0"
dm_pinged && ok "and it pinged"      || bad "and it pinged" "a call to hc-ping.com" "none"

# THE JOINT. deadman's threshold and the heartbeat's own MaxAge live in different
# files and nothing at runtime makes them agree — the same shape as the
# healthchecks.io cadence joint, which CLAUDE.md calls out as uncheckable. This one
# IS checkable, so it is checked: a threshold shorter than the watchdog's own limit
# would fire on a job the watchdog still considers fresh.
hb_declared="$(awk '
    /^\[/  { inside = ($0 == "[X-Catallenya]"); next }
    inside && index($0, "MaxAge=") == 1 { v = substr($0, 8) }
    END { if (v != "") print v }' "${REPO}/systemd/catallenya.heartbeat.service")"
hb_default="$(sed -n 's/^HEARTBEAT_MAX_AGE="\${HEARTBEAT_MAX_AGE:-\([^}]*\)}"/\1/p' "${REPO}/host/deadman.sh")"
is "deadman's threshold matches the heartbeat's declared MaxAge" "$hb_default" "$hb_declared"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
