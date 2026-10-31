#!/usr/bin/env bash
# Regression tests for the systemd job factory: the gate and the watchdog.
#
# Everything here runs offline and free. The gate is tested by breaking a COPY of
# a REAL unit and confirming it refuses — a synthetic fixture would only prove the
# gate agrees with a fixture, while the real file is never written: it is the live
# target of an /etc/systemd/system symlink, so the old sed-in-place version put
# broken content into the running config for the duration of every case (and left
# NeedDaemonReload drift plus mktemp-mode files behind — 2026-08-13 audit). The
# watchdog is tested against the per-user systemd manager, so real systemd does
# the parsing and drop-in merging rather than a mock that agrees with whatever the
# script already believes.
#
# Nothing here touches the system manager, /etc/systemd/system, or any file a
# system unit resolves. Run before commit:
#   bash systemd/tests/run.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${SELF_DIR}/../.." && pwd)"
INSTALL="${REPO}/systemd/install.sh"
HEARTBEAT="${REPO}/systemd/heartbeat.sh"

# Nothing here may reach the real phone. The watchdog cases run the REAL script,
# not a dry-run, so without this a failing round would publish to the live topic
# and the suite would look like it passed.
export NTFY_DISABLE=1

PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
has()  { [[ "$2" == *"$3"* ]] && ok "$1" || bad "$1" "contains: $3" "$2"; }
hasnt(){ [[ "$2" != *"$3"* ]] && ok "$1" || bad "$1" "must not contain: $3" "$2"; }

# ================================================================== the gate
#
# Each case mutates a COPY of one real unit inside CHECK_TREE and points the gate
# at that tree via INSTALL_CHECK_REPO (honored only under --check). No restore and
# no trap gymnastics: a suite killed mid-case leaves nothing behind but a temp
# directory, where the old in-place version left a deliberately broken unit as
# the running config.

CHECK_TREE="$(mktemp -d)"
PRISTINE_TREE="$(mktemp -d)"
trap 'rm -rf "$CHECK_TREE" "$PRISTINE_TREE"' EXIT
# Everything the gate reads, layout preserved: units, timers, paths, the policy
# fragments and the instance stickers.
# Every directory that can hold a unit. This list is load-bearing and easy to
# forget: a unit whose directory is missing here is simply absent from the check
# tree, so `gate_says` mutates a file that is not there, the gate finds nothing to
# refuse, and the case fails with the gate reporting success. Units moved out of
# systemd/ on 2026-08-15 (host/, changedetection/, immich/) broke 23 cases exactly
# that way, and liquidroom/systemd had been missing since it shipped.
(cd "$REPO" && find systemd restic host changedetection ntfy \
    afterimage/systemd pigeonhole/systemd ebooks/systemd liquidroom/systemd immich \
    radicale/feeds grayjay/systemd \
    \( -name '*.service' -o -name '*.timer' -o -name '*.path' -o -name '*.conf' \) \
    -exec cp --parents -t "$PRISTINE_TREE" {} +)

# The whole tree goes back to pristine before EVERY case. The old shape re-copied
# only the unit a case was about to mutate, so every OTHER unit kept whatever the
# cases before it had done — and two assertions passed on a lingering mutation
# from someone else's case rather than pinning their own (2026-08-19 audit).
restore_tree() { rsync -a --delete "${PRISTINE_TREE}/" "${CHECK_TREE}/"; }

# gate_says <name> <unit-path> <sed-expr> <expected substring>
gate_says() {
    local name="$1" unit="$2" expr="$3" want="$4"
    local rel="${unit#"${REPO}/"}"
    restore_tree
    sed -i -E "$expr" "${CHECK_TREE}/${rel}"
    local out; out="$(INSTALL_CHECK_REPO="$CHECK_TREE" bash "$INSTALL" --check 2>&1)"
    has "$name" "$out" "$want"
}

echo "gate — refuses what the contract forbids"

gate_says "no Class= is refused" \
    "${REPO}/host/disk.service" '/^Class=monitor$/d' "no [X-Catallenya] Class="

gate_says "unknown Class= is refused" \
    "${REPO}/host/disk.service" 's/^Class=monitor$/Class=wibble/' "unknown Class=wibble"

gate_says "scheduled without TimeoutStartSec is refused" \
    "${REPO}/restic/forget/restic.forget.service" '/^TimeoutStartSec=/d' \
    "requires an explicit finite TimeoutStartSec"

gate_says "scheduled without MaxAge is refused" \
    "${REPO}/restic/forget/restic.forget.service" '/^MaxAge=/d' "requires MaxAge="

gate_says "monitor declaring Freshness is refused" \
    "${REPO}/host/disk.service" 's/^MaxAge=3h$/MaxAge=3h\nFreshness=stamp:\/tmp\/x/' \
    "must not declare Freshness="

gate_says "monitor setting its own TimeoutStartSec is refused" \
    "${REPO}/host/disk.service" 's/^ExecStart=/TimeoutStartSec=5min\nExecStart=/' \
    "must not set TimeoutStartSec"

gate_says "adhoc declaring MaxAge is refused" \
    "${REPO}/afterimage/systemd/afterimage.triage.service" 's/^Class=adhoc$/Class=adhoc\nMaxAge=1h/' \
    "must not declare MaxAge="

gate_says "a root job without CapabilityBoundingSet is refused" \
    "${REPO}/host/zpool.scrub.service" '/^CapabilityBoundingSet=/d' \
    "runs as root without a CapabilityBoundingSet"

# CANCELLING OnFailure= SWITCHES OFF A JOB'S FAILURE ALERTING. An empty assignment
# resets the list systemd would otherwise append to, so one line makes a job that
# fails do so in silence — the same class the Condition*= rule guards, reached from
# the other direction. Legitimate for a job that sends its own message; never
# legitimate quietly, because a later reader cannot tell an exemption from a mistake.
#
# Same escape-hatch shape as UnboundedRoot=acknowledged.
gate_says "cancelling OnFailure= without declaring it is refused" \
    "${REPO}/host/disk.service" 's/^\[Service\]$/OnFailure=\n[Service]/' \
    "cancels its inherited OnFailure="
gate_says "and the acknowledgement is what clears it" \
    "${REPO}/host/disk.service" 's/^\[Service\]$/OnFailure=\n[Service]/; s/^Class=monitor$/Class=monitor\nSelfAlerting=acknowledged/' \
    "52 units satisfy the contract"

gate_says "a missing User= is refused" \
    "${REPO}/host/disk.service" '/^User=/d' "no explicit User="

gate_says "Condition*= is refused in favour of Requires=" \
    "${REPO}/host/disk.service" 's/^ExecStart=/ConditionPathExists=\/tmp\nExecStart=/' \
    "A failed Condition is a SKIP"

gate_says "RuntimeMaxSec= is refused as a no-op on oneshot" \
    "${REPO}/host/disk.service" 's/^ExecStart=/RuntimeMaxSec=5min\nExecStart=/' \
    "systemd IGNORES on Type=oneshot"

gate_says "re-setting a factory scalar is refused" \
    "${REPO}/host/disk.service" 's/^ExecStart=/PrivateTmp=true\nExecStart=/' \
    "the unit's value is silently discarded"

# systemd answers a missing +x bit with 203/EXEC and names no cause. On a
# .path-driven job that is a spin: watcher re-fires, service fails, OnFailure=
# alerts, repeat until the class start limit stops it. liquidroom.triage shipped
# exactly this and cost five notifications before anyone could read the mode.
# A *.lib.sh is the natural fixture — sourced, never executed, so 0644 by design.
gate_says "a non-executable ExecStart is refused" \
    "${REPO}/host/disk.service" \
    's|^ExecStart=.*|ExecStart=/zpool/catallenya/pigeonhole/scripts/pigeonhole.lib.sh|' \
    "is not executable"

gate_says "a missing ExecStart target is refused" \
    "${REPO}/host/disk.service" \
    's|^ExecStart=.*|ExecStart=/zpool/catallenya/nope/missing.sh|' \
    "does not exist"

gate_says "an unrecognised Freshness form is refused" \
    "${REPO}/restic/forget/restic.forget.service" 's|^Freshness=.*|Freshness=/tmp/whatever|' \
    "is not a recognised form"

gate_says "a timer without RandomizedDelaySec is refused" \
    "${REPO}/host/disk.timer" '/^RandomizedDelaySec=/d' "no RandomizedDelaySec="

gate_says "a timer re-declaring [Install] is refused" \
    "${REPO}/host/disk.timer" 's|^\[Timer\]|[Install]\nWantedBy=timers.target\n\n[Timer]|' \
    "declares its own [Install]"

# --- cases the adversarial pass earned; each defeated the gate before the fix ---
gate_says "User=0 counts as root" \
    "${REPO}/host/zpool.scrub.service" 's/^User=root$/User=0/;/^CapabilityBoundingSet=/d' \
    "runs as root without a CapabilityBoundingSet"

gate_says "a trailing space does not hide root" \
    "${REPO}/host/zpool.scrub.service" 's/^User=root$/User=root /;/^CapabilityBoundingSet=/d' \
    "runs as root without a CapabilityBoundingSet"

gate_says "the LAST User= wins, as systemd does" \
    "${REPO}/host/disk.service" 's/^User=carrein$/User=carrein\nUser=root/' \
    "runs as root without a CapabilityBoundingSet"

gate_says "a capability bound outside [Service] does not count" \
    "${REPO}/host/zpool.scrub.service" 's|^CapabilityBoundingSet=.*|#moved|;s|^\[Unit\]|[Unit]\nCapabilityBoundingSet=CAP_SYS_ADMIN|' \
    "without a CapabilityBoundingSet= in [Service]"

gate_says "an indented Condition is still refused" \
    "${REPO}/host/disk.service" 's/^ExecStart=/  ConditionPathExists=\/tmp\nExecStart=/' \
    "A failed Condition is a SKIP"

gate_says "ExecStart=- is refused (false healthy stamp)" \
    "${REPO}/host/disk.service" 's|^ExecStart=|ExecStart=-|' \
    "would be written anyway"

gate_says "SuccessExitStatus= is refused (false healthy stamp)" \
    "${REPO}/host/disk.service" 's/^ExecStart=/SuccessExitStatus=1\nExecStart=/' \
    "count as success"

gate_says "a monitor declaring OnSuccess= is refused" \
    "${REPO}/host/disk.service" 's|^\[Unit\]|[Unit]\nOnSuccess=system-ntfy@disk.service|' \
    "must not declare OnSuccess="

# The exemption must be EXPLICIT: absent is still refused, acknowledged passes.
# Otherwise "forgot to bound it" and "decided not to" look the same.
gate_says "unbounded root without acknowledgement is still refused" \
    "${REPO}/host/zpool.scrub.service" '/^CapabilityBoundingSet=/d' \
    "bound it, or declare"

gate_says "an adhoc watcher without Producer= is refused" \
    "${REPO}/afterimage/systemd/afterimage.triage.service" '/^Producer=/d' \
    "must declare Producer= naming what feeds it"

gate_says "MaxAge=infinity is refused (disables its own check)" \
    "${REPO}/host/disk.service" 's/^MaxAge=3h$/MaxAge=infinity/' \
    "does not parse to a usable finite timespan"

gate_says "a timer re-setting Persistent= is refused" \
    "${REPO}/host/disk.timer" 's/^OnCalendar=/Persistent=true\nOnCalendar=/' \
    "already sets"

# --- cases the 2026-08-19 audit earned; each defeated the gate before the fix ---

# The old requirement check fell back to a section-blind grep, so a required
# directive parked in [Unit] — where systemd ignores it — still counted as
# present. The job then ran at the oneshot default: TimeoutStartSec=infinity.
gate_says "TimeoutStartSec= in [Unit] does not satisfy the requirement" \
    "${REPO}/restic/forget/restic.forget.service" \
    's|^TimeoutStartSec=2h$|#moved|;s|^\[Unit\]|[Unit]\nTimeoutStartSec=2h|' \
    "requires an explicit finite TimeoutStartSec"

# Worse than a missing bound: User= in [Unit] means systemd runs the unit as
# ROOT, and the section-blind check ALSO skipped the unbounded-root refusal,
# because the section-aware reader correctly saw no [Service] User at all.
gate_says "User= in [Unit] does not satisfy the requirement" \
    "${REPO}/host/disk.service" \
    's|^User=carrein$|#moved|;s|^\[Unit\]|[Unit]\nUser=carrein|' \
    "no explicit User="

# .path units were entirely undispatched until 2026-08-19 — a watcher full of
# garbage passed the gate clean. The Condition trap is the one that bites
# silently: a skipped watcher looks installed and never fires.
gate_says "Condition*= on a .path unit is refused" \
    "${REPO}/afterimage/systemd/afterimage.triage.path" \
    's|^\[Unit\]|[Unit]\nConditionPathIsMountPoint=/zpool|' \
    "A failed Condition is a SKIP"

# A committed-but-unregistered unit validates nothing, installs nothing, and is
# invisible to the watchdog — a rogue with six violations once sailed past as
# "OK 40 units". Not gate_says: the mutation is a NEW file, not a sed.
restore_tree
printf '%s\n' "[Service]" "ExecStart=/bin/true" > "${CHECK_TREE}/host/zzrogue.service"
out="$(INSTALL_CHECK_REPO="$CHECK_TREE" bash "$INSTALL" --check 2>&1)"
has "an unregistered unit in the tree is refused" "$out" "not in install.sh's SYMLINKS map"

# The prune loop once deleted the instance sticker directories this same script
# creates, because a template instance has no unit file of its own. Both restic
# check jobs came out of a real install with no MaxAge and no Freshness.
has "instance stickers are exempt from the orphan prune" \
    "$(grep -c 'template INSTANCE never has a unit file' "$INSTALL")" "1"

# ProtectHome=read-only from the monitor class blocks restic's cache, and restic
# exits 1 rather than degrading — so the job watching your backups failed nightly.
has "restic.staleness keeps its cache writable" \
    "$(cat "${REPO}/restic/staleness/restic.staleness.service")" "ReadWritePaths=/home/carrein/.cache/restic"

# And the other half: the unmutated tree must pass, or every case above is
# meaningless.
out="$(bash "$INSTALL" --check 2>&1)"
has "the real tree satisfies the contract" "$out" "contract satisfied"
hasnt "a passing check installs nothing" "$out" "Creating unit symlinks"

# ============================================================== the watchdog
#
# Fixtures live in the per-user manager so `systemctl --user cat` does the drop-in
# merging for real. HEARTBEAT_SYSTEMD_DIR points enumeration at the same place.

# Fixtures must live in the per-user unit directory for `systemctl --user cat` to
# see them — but enumeration must NOT glob that directory, because it is shared:
# any stray user unit carrying a Class= would join the roll call and break the
# counts. So the unit files go to UD for systemd, and a COPY of each goes to a
# private ENUM dir that the watchdog globs. The suite then sees exactly its own
# fixtures no matter what else is installed.
UD="${HOME}/.config/systemd/user"
STATE="$(mktemp -d)"
ENUM="${STATE}/enum"
FIXTURES=()
mkdir -p "${UD}" "${STATE}/systemd/state" "${ENUM}"

hb_cleanup() {
    for f in "${FIXTURES[@]:-}"; do [[ -n "$f" ]] && rm -f "${UD}/${f}"; done
    rm -rf "$STATE"
    systemctl --user daemon-reload 2>/dev/null
    rm -rf "$CHECK_TREE" "$PRISTINE_TREE"
}
trap hb_cleanup EXIT

# fixture <name> <body...>  — writes a zzhb-prefixed user unit
fixture() {
    local n="$1"; shift
    printf '%s\n' "$@" > "${UD}/${n}"
    cp "${UD}/${n}" "${ENUM}/${n}"
    FIXTURES+=("$n")
}

# run_hb [uptime-seconds] — uptime is pinned so the suite does not change its
# answers depending on when the HOST last rebooted: the stale-stamp cases assert
# STALE, which the downtime check would demote to WAS OFF on a freshly-booted box.
run_hb() {
    HEARTBEAT_ADOPTED="" \
    HEARTBEAT_SYSTEMD_DIR="$ENUM" \
    HEARTBEAT_REPO_DIR="$STATE" \
    HEARTBEAT_SYSTEMCTL="systemctl --user" \
    HEARTBEAT_UPTIME_S="${1:-604800}" \
    bash "$HEARTBEAT" 2>&1
}

echo
echo "watchdog — every finding type"

fixture "zzhb-fresh.service" \
    "[Service]" "Type=oneshot" "ExecStart=/bin/true" \
    "" "[X-Catallenya]" "Class=scheduled" "MaxAge=36h" "Freshness=stamp:${STATE}/fresh"
touch "${STATE}/fresh"

fixture "zzhb-stale.service" \
    "[Service]" "Type=oneshot" "ExecStart=/bin/true" \
    "" "[X-Catallenya]" "Class=scheduled" "MaxAge=1h" "Freshness=stamp:${STATE}/stale"
touch -d '3 days ago' "${STATE}/stale"

fixture "zzhb-never.service" \
    "[Service]" "Type=oneshot" "ExecStart=/bin/true" \
    "" "[X-Catallenya]" "Class=scheduled" "MaxAge=36h" "Freshness=stamp:${STATE}/absent"

fixture "zzhb-nofresh.service" \
    "[Service]" "Type=oneshot" "ExecStart=/bin/true" \
    "" "[X-Catallenya]" "Class=scheduled" "MaxAge=36h"

fixture "zzhb-badage.service" \
    "[Service]" "Type=oneshot" "ExecStart=/bin/true" \
    "" "[X-Catallenya]" "Class=scheduled" "MaxAge=bananas" "Freshness=stamp:${STATE}/fresh"

fixture "zzhb-badfresh.service" \
    "[Service]" "Type=oneshot" "ExecStart=/bin/true" \
    "" "[X-Catallenya]" "Class=scheduled" "MaxAge=36h" "Freshness=telepathy:hope"

# Producer=: an armed watcher proves nothing can reach it.
fixture "zzhb-noproducer.service" \
    "[Service]" "Type=oneshot" "ExecStart=/bin/true" \
    "" "[X-Catallenya]" "Class=adhoc" "Freshness=unit:zzhb-nonexistent.path" \
    "Producer=container:zzhb-no-such-container"

fixture "zzhb-badproducer.service" \
    "[Service]" "Type=oneshot" "ExecStart=/bin/true" \
    "" "[X-Catallenya]" "Class=adhoc" "Freshness=unit:zzhb-nonexistent.path" \
    "Producer=telepathy:hope"

fixture "zzhb-unarmed.service" \
    "[Service]" "Type=oneshot" "ExecStart=/bin/true" \
    "" "[X-Catallenya]" "Class=adhoc" "Freshness=unit:zzhb-nonexistent.path"

# A monitor never declares Freshness — the watchdog must imply the stamp path
# from REPO_DIR, which is the one piece of the contract that lives in two places.
fixture "zzhb-monitor.service" \
    "[Service]" "Type=oneshot" "ExecStart=/bin/true" \
    "" "[X-Catallenya]" "Class=monitor" "MaxAge=1h"
touch -d '5 days ago' "${STATE}/systemd/state/zzhb-monitor"

systemctl --user daemon-reload 2>/dev/null
OUT="$(run_hb)"

has  "a fresh stamp raises nothing"        "$OUT" "ok zzhb-fresh.service"
hasnt "…and appears in no finding"          "$(grep -E '^(STALE|NEVER)' <<<"$OUT")" "zzhb-fresh"
has  "a stale stamp is STALE"              "$OUT" "STALE"
has  "…naming the job and its age"         "$OUT" "zzhb-stale.service — last completed 3d"
has  "a missing stamp is NEVER RAN"        "$OUT" "NEVER RAN     zzhb-never.service"
has  "Class without Freshness is caught"   "$OUT" "NO STICKER    zzhb-nofresh.service"
has  "an unparseable MaxAge is caught"     "$OUT" "BAD STICKER   zzhb-badage.service"
has  "an unknown Freshness form is caught" "$OUT" "BAD STICKER   zzhb-badfresh.service"
has  "a dead .path unit is UNARMED"        "$OUT" "UNARMED       zzhb-unarmed.service"
has  "a missing producer is caught"        "$OUT" "NO PRODUCER   zzhb-noproducer.service"
# A deliberately masked foreign unit (avahi is masked on this box on purpose) must
# not be reported. Only our own units count as a MASKED finding.
hasnt "a foreign masked unit is not reported" "$OUT" "MASKED"
has  "…naming the container"               "$OUT" "zzhb-no-such-container"
has  "an unknown Producer form is caught"  "$OUT" "BAD STICKER   zzhb-badproducer.service"
has  "a monitor's stamp path is implied"   "$OUT" "STALE         zzhb-monitor.service"
# The point of this one: two fixtures have deliberately broken stickers, and a
# round that aborted on the first would still print findings for everything before
# it. Only the count proves every job was reached.
has  "one bad sticker does not abort the round" "$OUT" "checked 10 job(s)"
hasnt "nothing is published under NTFY_DISABLE" "$OUT" "publish failed"
has  "…and it says so"                     "$OUT" "NTFY_DISABLE=1, not publishing"

# All-clear path: remove every unhealthy fixture, leaving only the fresh one.
for f in stale never nofresh badage badfresh unarmed monitor noproducer badproducer; do rm -f "${UD}/zzhb-${f}.service" "${ENUM}/zzhb-${f}.service"; done
systemctl --user daemon-reload 2>/dev/null
CLEAR="$(run_hb)"
has  "a healthy round says all clear" "$CLEAR" "all clear"
hasnt "…and raises no findings"       "$CLEAR" "STALE"

# --- the WAS OFF window is min(MaxAge, 24h), not MaxAge ----------------------
#
# The first version compared uptime against MaxAge, so the then-yearly
# restic.check@data (MaxAge=400d, retired 2026-08-22) could never page on a box
# that ever reboots, and any reboot muted every long-cadence job for its whole
# MaxAge. The fixtures below pin that behaviour, not that unit: the grace still
# suppresses right after boot, and it caps at a day instead of scaling with MaxAge.
fixture "zzhb-shortoff.service" \
    "[Service]" "Type=oneshot" "ExecStart=/bin/true" \
    "" "[X-Catallenya]" "Class=scheduled" "MaxAge=1h" "Freshness=stamp:${STATE}/shortoff"
touch -d '3 days ago' "${STATE}/shortoff"

fixture "zzhb-longstale.service" \
    "[Service]" "Type=oneshot" "ExecStart=/bin/true" \
    "" "[X-Catallenya]" "Class=scheduled" "MaxAge=1000d" "Freshness=stamp:${STATE}/longstale"
touch -d '1001 days ago' "${STATE}/longstale"

systemctl --user daemon-reload 2>/dev/null

BOOTED="$(run_hb 1800)"      # 30 minutes up: inside the grace
has   "just after boot a stale job is downtime, not a page" "$BOOTED" "WAS OFF"
hasnt "…so it raises no STALE for it" "$(grep -E '^STALE' <<<"$BOOTED")" "zzhb-shortoff"

DAYSUP="$(run_hb 172800)"    # 2 days up: far inside MaxAge=1000d, past the grace
has   "a long-MaxAge job pages once the grace passes" "$DAYSUP" "STALE         zzhb-longstale.service"

for f in shortoff longstale; do rm -f "${UD}/zzhb-${f}.service" "${ENUM}/zzhb-${f}.service"; done
systemctl --user daemon-reload 2>/dev/null

# The adopted units are the two whose documented failure mode is going quiet, and
# neither can appear in the symlink-based drift pass — catallenya.service is a
# regular file, sanoid's fragment lives under /usr. So "absent" must read as a
# finding, not as fine.
ADOPT="$(HEARTBEAT_SYSTEMD_DIR="$ENUM" HEARTBEAT_REPO_DIR="$STATE" \
         HEARTBEAT_SYSTEMCTL="systemctl --user" bash "$HEARTBEAT" 2>&1)"
has  "an adopted unit with no sticker is reported" "$ADOPT" "NO STICKER    sanoid.service"
has  "…including sanoid-prune"                     "$ADOPT" "NO STICKER    sanoid-prune.service"
has  "…and the boot orchestrator"                  "$ADOPT" "catallenya.service"

# --------------------------------------------------------- units in `failed`
#
# A unit's failure is announced ONCE, by the courier, at the moment it happens. If
# that alert never lands the unit sits failed forever and nothing mentions it again
# — every freshness check above can still pass, because "ran recently" and "ran
# successfully" are different questions. Added 2026-08-24 alongside the two courier
# fixes: those make the first alert reliable, this makes it non-unique.
fixture "zzhb-broken.service" \
    "[Service]" "Type=oneshot" "ExecStart=/bin/false" \
    "" "[X-Catallenya]" "Class=scheduled" "MaxAge=36h" "Freshness=stamp:${STATE}/fresh"
systemctl --user daemon-reload 2>/dev/null
systemctl --user start zzhb-broken.service 2>/dev/null || true

FAILEDOUT="$(run_hb)"
has  "a unit sitting in failed is reported"  "$FAILEDOUT" "zzhb-broken.service"
has  "…and says why that matters"            "$FAILEDOUT" "nothing will mention it again"

# The negative half. Without it the case would pass just as well if the sweep
# reported EVERY unit, which is the commonest way this kind of check rots.
hasnt "a healthy unit is not reported as failed" \
      "$(printf '%s' "$FAILEDOUT" | grep -i 'FAILED' || true)" "zzhb-fresh.service"

systemctl --user reset-failed zzhb-broken.service 2>/dev/null || true
# Scoped to FAILED lines on purpose. The unit is still a registered job, so it
# rightly keeps appearing in the roll call as `ok` — asserting the name is absent
# entirely would be asserting the wrong thing, and would fail against correct code.
hasnt "and it stops being reported once cleared" \
      "$(run_hb | grep -i 'FAILED' || true)" "zzhb-broken.service"
rm -f "${UD}/zzhb-broken.service" "${ENUM}/zzhb-broken.service"
systemctl --user daemon-reload 2>/dev/null

# ============================================================== the courier
#
# Ownership is fragment-under-repo OR a Class in the merged view — the second
# clause is what lets adopted vendor units (the sanoid pair, fragments under
# /usr) reach the phone; before it, their OnFailure= called a courier that
# refused them, silently. NTFY_DISABLE stops just short of the wire, so
# ownership, routing and title derivation are all exercised for real. These
# cases read the SYSTEM manager (read-only) and need the real units installed,
# which on this box they always are.
SN="${REPO}/ntfy/system-ntfy.sh"

OUT="$(NTFY_DISABLE=1 bash "$SN" sanoid 2>&1)"
has  "courier accepts an adopted vendor unit"  "$OUT" "not publishing"

OUT="$(NTFY_DISABLE=1 bash "$SN" disk 2>&1)"
has  "courier still accepts a repo unit"       "$OUT" "not publishing"

if OUT="$(NTFY_DISABLE=1 bash "$SN" cron 2>&1)"; then
    bad "courier refuses a foreign unit" "non-zero exit" "exit 0: $OUT"
else
    has "courier refuses a foreign unit"       "$OUT" "refusing to publish"
fi

# The stickers install.sh writes must carry the two contract halves a vendor
# unit cannot inherit: the crash wire and a finite hang bound.
has "adopted stickers carry the crash wire"  "$(grep -c 'OnFailure=system-ntfy@%N.service' "$INSTALL")" "2"
has "adopted stickers carry a finite bound"  "$(grep -c 'TimeoutStartSec=1h' "$INSTALL")" "2"

# sticker() exists twice on purpose — the gate reads the unit FILE, the watchdog
# reads `systemctl cat` — but the awk between those framings must stay
# byte-identical. They once disagreed on first-vs-last match, so a unit with two
# MaxAge= lines showed the gate one value and the watchdog another: two jobs dead
# for a year while both layers reported them healthy. A textual pin is enough;
# the comment on each copy says why.
sticker_awk() {
    awk '/^sticker\(\) \{/,/^\}/' "$1" \
        | sed -n "/awk -v k=/,/^[[:space:]]*'/p" | sed '1d;$d'
}
GATE_AWK="$(sticker_awk "$INSTALL")"
HB_AWK="$(sticker_awk "$HEARTBEAT")"
if [[ -n "$GATE_AWK" && -n "$HB_AWK" ]]; then
    ok "both sticker() awk bodies extract non-empty"
else
    bad "both sticker() awk bodies extract non-empty" "three awk lines from each file" "install.sh: '${GATE_AWK:-<empty>}' heartbeat.sh: '${HB_AWK:-<empty>}'"
fi
if [[ -n "$GATE_AWK" && "$GATE_AWK" == "$HB_AWK" ]]; then
    ok "the two sticker() readers are byte-identical"
else
    bad "the two sticker() readers are byte-identical" "identical awk bodies" "$(printf 'install.sh:\n%s\nheartbeat.sh:\n%s' "$GATE_AWK" "$HB_AWK")"
fi

echo
# ------------------------------------------------- the intake code contract
# Everything above tests the gate against a UNIT. These test it against the CODE an
# intake job runs, which is where the three regressions most likely to come back
# actually live. The check tree copies units and not scripts, so a violation is
# staged in a contract_fixture directory instead of by editing a live pipeline.
echo "intake contract"

# shellcheck source=../contract.sh
# The contract accumulates into ERRORS via err(), exactly as the gate does.
ERRORS=(); err() { ERRORS+=("$1"); }
# shellcheck source=../contract.sh
source "${REPO}/systemd/contract.sh"
FIX="$(mktemp -d)"; mkdir -p "${FIX}/scripts"
# NOT fixture(): this suite already has one, for units. Two functions sharing a
# name in one file is ambiguous to a reader and to shellcheck (SC2218), even
# though bash happens to resolve it by position.
contract_fixture() { printf '%s\n' "$1" > "${FIX}/scripts/thing.sh"; }
contract_says() { # $1=name $2=expected substring
    ERRORS=(); intake_contract "$FIX" fixture
    local joined="${ERRORS[*]:-}"
    [[ "$joined" == *"$2"* ]] && ok "$1" || bad "$1" "contains $2" "${joined:-<no error>}"
}
contract_clean() { # $1=name
    ERRORS=(); intake_contract "$FIX" fixture
    (( ${#ERRORS[@]} == 0 )) && ok "$1" || bad "$1" "no error" "${ERRORS[*]}"
}

contract_fixture 'notify() {
    curl -sS "$@"
}'
contract_says "a fifth copy of notify() is refused" "defines its own notify()"

contract_fixture 'retract() {
    curl -X DELETE "$1"
}'
contract_says "so is a private retract()" "defines its own retract()"

contract_fixture 'notify "Something Broke" high warning "body"'
contract_says "high priority is refused" "high priority"

# The live escape shipped WRAPPED: `notify "…" \` with the priority on the next
# line is one command to bash and was invisible to a line-based grep — the
# single-line case above was vacuous against the bug's real shape.
contract_fixture 'notify "Refused: 3 Documents" \
    high warning "$body"'
contract_says "a wrapped high is still refused" "high priority"

contract_fixture 'out="$(api_post "$msgf")" || rc=$?
if (( rc == 2 )); then park; else resolve; fi'
contract_says "reading the API as pass/fail is refused" "never branches on rc 3"

contract_fixture 'out="$(api_post "$msgf")" || rc=$?
if (( rc == 2 || rc == 3 )); then park; else resolve; fi'
contract_clean "and handling all four verdicts passes"

# The rule must not fire on the comments left to explain the rule. Both live intake
# libs discuss api_post and high priority in exactly that way.
contract_fixture '# api_post moved to ai.lib.sh; nothing here calls it any more.
# It used to notify at high priority, which nothing does now.
echo hello'
contract_clean "prose about the rule is not a violation"

# --- the message contract: titles come from constructors ---------------------
# Rule 1 of the message contract is the load-bearing one. Unlike systemd/policy/,
# there is no merge engine underneath these constructors — nothing at runtime stops a
# caller passing notify() a hand-built string, so the gate refusing it IS the
# layering. See ntfy/MESSAGES.md § 8.
contract_fixture 'notify_fault "Disk Space Alert" "$ALERT"'
contract_says "a hand-built title is refused" "builds a notification title by hand"

# The same shape that let `high` survive nine days. A line-based check on the title
# rule would be vacuous against the bug this repo has actually had.
contract_fixture 'notify_fault \
    "Boot Failure" "$body"'
contract_says "a WRAPPED hand-built title is refused" "builds a notification title by hand"

contract_fixture 'notify_receipt "$(title_count Staged 3 Document)" "$body"'
contract_clean "an inline constructor passes"

# Two live call sites need a variable: pigeonhole picks between `Blocked` and
# `Model Failed` on the blocked code, afterimage builds a quotation once and reuses
# it. The title still comes from a constructor, so the rule follows the assignment.
contract_fixture 't="$(title_quote "$name" "$(title_pos 2 4)")"
notify_proposal "$t" "$body" "$acts" "$id"'
contract_clean "a variable assigned from a constructor passes"

contract_fixture 't="Boot Failure"
notify_fault "$t" "$body"'
contract_says "a variable holding a literal does not" "builds a notification title by hand"

# --- the message contract: declared verbs are past participles ---------------
# The gate can check that a title's verb was declared, but the DECLARATION is where a
# new service would otherwise break the rule silently.
contract_fixture 'NTFY_VERBS=(Processing Uploaded)'
contract_says "a present participle is refused" "not a past participle"

# Both of these were proposed during the design of this contract and both are
# adjectives. A looser check — rejecting "-ing" only — would have waved them through,
# which is the whole reason the rule is "ends in ed" plus a one-entry allowlist.
contract_fixture 'NTFY_VERBS=(Stray Unclear)'
contract_says "and so is an adjective" "not a past participle"

contract_fixture 'NTFY_VERBS=(Stuck Staged Binned)'
contract_clean "the one irregular on the allowlist passes"

# --- the message contract: the envelope --------------------------------------
# notify() is the transport primitive and every job goes through a KIND, because the
# kind is what makes the lifecycle rules structural: notify_receipt has no argument to
# put a button in, notify_proposal cannot omit the sequence-id that makes it
# withdrawable. A bare call bypasses all of it.
contract_fixture 'notify "$(title_count Staged 3 Document)" "$body"'
contract_says "a bare notify() is refused" "calls notify() directly"

# Wrapped, because that is the shape the one live `high` shipped in.
contract_fixture 'notify \
   "$(title_state zpool "78% Full")" "$body"'
contract_says "and a WRAPPED bare notify() too" "calls notify() directly"

contract_fixture 'notify_receipt "$(title_count Baked 3 Rotation)" "$body"'
contract_clean "a kind passes"

# clear=true dismisses on the TAP, before the work behind the button has happened, so
# a refused move would leave the notification gone and the document unmoved — with the
# buttons that were the only way to act now off the phone.
contract_fixture 'acts="view, Accept, ${BASE}/a, clear=true"
notify_proposal "$(title_count Staged 3 Document)" "$b" "$acts" "$id"'
contract_says "clear=true is refused" "clear=true"

# --- the message contract: the body ------------------------------------------
# A literal "1\." is what FOUR files each discovered separately on the phone (Android
# renders real ordered-list markers as unnumbered dots, so the numbers vanish), and
# each then grew its own five-item cap, its own "… and N more" tail and its own NBSP
# indent — two of which were already different widths by the time they were collected.
contract_fixture 'body+="${n}\\. ${l}"
notify_receipt "$(title_count Downloaded 2 Track)" "$body"'
contract_says "a hand-built numbered list is refused" "numbered list by hand"

contract_fixture 'body="1\\. $(md_escape "$orig")"
notify_receipt "$(title_count Binned 1 Document)" "$body"'
contract_says "…including a single hardcoded item" "numbered list by hand"

contract_fixture 'notify_receipt "$(title_count Downloaded 2 Track)" "$(body_list "${items[@]}")"'
contract_clean "the renderer passes"

# Italics mean a truncation count and nothing else — narrowed 2026-08-21, because
# italics that mean several things mean nothing. They had been carrying ETAs, parked
# reasons and the one sentence a binned note existed to say.
contract_fixture 'body+="_In bin/ after 7 days with no decision._"
notify_resolved "$(title_count Binned 1 Document)" "$body" "$id" "$acts"'
contract_says "a hand-built italic line is refused" "italic line by hand"

# The shape paused_body shipped in for a year: italics inside a printf FORMAT string,
# which a pattern anchored on a leading `"_` walks straight past.
contract_fixture 'printf "%s\n_%s. Retrying daily — %s._" "$out" "$reason" "$outcome"
notify_fault "$(title_count "Model Paused" 2 Document)" "$body"'
contract_says "…including one inside a printf format" "italic line by hand"

contract_fixture 'notify_receipt "$(title_count Passed 3 Event)" "$(body_join "$(body_list "${t[@]}")" "$(body_aside "3 more not sent")")"'
contract_clean "body_aside passes"

# The renderers escape link syntax out of everything untrusted, but PROSE reaches
# body_join unescaped — so a hand-authored link is the one way a live one gets into a
# notification. A BARE URL is fine and is load-bearing in changedetection's body.
contract_fixture 'notify_fault "$(title_state Boot Failed)" "$(body_join "" "See [the runbook](https://example.com/x)")"'
contract_says "a markdown link in a body is refused" "markdown link into a body"

contract_fixture 'notify_fault "$(title_state Boot Failed)" "$(body_join "" "See https://example.com/x")"'
contract_clean "a bare URL passes"

# A nudge is the same decision asked twice. A title identical to the first asking
# cannot be told from it — you do not know whether you already saw this one.
contract_fixture 'notify_nudge "$(title_count Staged 3 Document)" "$b" "$id"'
contract_says "a nudge that reads like a first ask is refused" "does not read as one"

contract_fixture 'notify_nudge "$(title_count "Still Staged" 3 Document)" "$b" "$id"'
contract_clean "a Still verb satisfies it"

# afterimage's proposal nudge has no verb to prefix — its title is a quotation — so
# the age bracket is what marks it.
contract_fixture 'notify_nudge "$(title_quote "$t" "$(title_age "$h")")" "$b" "$id"'
contract_clean "and so does an age bracket"

rm -rf "$FIX"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
