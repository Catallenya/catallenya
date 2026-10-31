#!/bin/bash
# Container fleet monitor — the roll call the 26 containers never had.
#
# The 20 systemd jobs have catallenya.heartbeat. The containers had nothing, and
# `restart: unless-stopped` is what makes that dangerous rather than merely missing:
# a container that crashes on startup oscillates forever without ever being "failed",
# so docker reports it as running-ish, systemd never hears about it, and the only
# thing that notices is a human opening the app and finding it dead.
#
# Nineteen containers publish a healthcheck that, until this job existed, NOTHING
# consumed. Seven publish none at all — and ntfy is one of the seven, which is the
# case that matters most: when ntfy dies every other alert in this fleet is dropped
# with no trace, so the alert channel was the single least observed thing on the box.
#
# Silent when healthy, like disk.sh, smart.sh and restic.staleness. Publishes to the
# `host` topic — the same channel boot events and the watchdog roll call use, because
# this is the same question asked about a different population, and an unsubscribed
# monitoring topic swallows alerts with a 200 OK.
set -euo pipefail

# shellcheck disable=SC2034  # read by ntfy.lib.sh, sourced below
NTFY_TOPIC="host"

# ONE STABLE ID FOR THE WHOLE RUN, not one per container. This runs hourly and
# re-reports an unfixed condition every hour, so without an id a container down over
# a weekend would produce forty-eight notifications — the exact pile disk.sh's id
# exists to prevent.
#
# Per RUN rather than per CONTAINER, which is where this differs from smart.sh: that
# job watches three fixed devices whose faults are independent, while a fleet failure
# is usually correlated (docker restarts, the box reboots, a compose edit lands) and
# arrives as one event with N symptoms. One message listing them is what you want to
# read at a glance; twenty-six that replace each other individually is not.
#
# It does NOT self-clear when the fleet recovers. A fault has no buttons, and a
# notification without buttons is never withdrawn by the system — an absent message is
# ambiguous, a stale one is not. See ntfy/MESSAGES.md § 4.
CONTAINERS_NTFY_ID="containers"
# shellcheck source=/zpool/catallenya/ntfy/ntfy.lib.sh
source "/zpool/catallenya/ntfy/ntfy.lib.sh"

# Test seam, the same shape as SMARTCTL in smart.sh and NTFY_DISABLE in the transport.
# Point it at a script that replays captured `compose config`, `ps` and `inspect`
# output and every branch below runs without docker. Never set in production.
DOCKER="${DOCKER:-docker}"

COMPOSE_FILE="${CONTAINERS_COMPOSE:-/zpool/catallenya/docker-compose.yml}"
PROJECT="catallenya"

# What was expected last time, and how many times each container had restarted.
# systemd/state/ is this box's one place for a job's own runtime record, and
# 10-base.conf grants every unit write access to it — which is what makes this
# writable under the monitor class's ProtectSystem=strict.
STATE_FILE="${CONTAINERS_STATE:-/zpool/catallenya/systemd/state/.containers-seen}"

# A container still reporting `starting` this long after it launched has a healthcheck
# that never passes, which is indistinguishable from a healthy container to anything
# that only asks "is it running". Fifteen minutes clears every legitimate warm-up here
# — immich-machine-learning is the slowest and settles in about two.
HEALTH_START_GRACE=900

# Restarts since the previous run before this calls it a loop. Watchtower RECREATES a
# container on update rather than restarting it, and a fresh container starts at zero,
# so this counter is not touched by the ordinary update path — an increase is a real
# crash-restart. One is a blip that healed itself; three within an hour is a loop.
RESTART_LOOP_DELTA=3

# How long to wait before believing a finding. Watchtower polls hourly and a recreate
# leaves a second or two where a container is `created` or briefly absent, which would
# otherwise page every time an image updates — and an alert that cries wolf on a
# healthy box trains you to ignore the topic that also carries a dead ntfy. Only
# findings present in BOTH passes are sent. Costs nothing on a healthy run, which
# never reaches the second pass.
RECHECK_SECONDS="${RECHECK_SECONDS:-20}"

# --- state -------------------------------------------------------------------
# The previous run's expectations. The KEY SET is what compose declared last time and
# the VALUE is that container's restart counter, so one file answers both "did a
# service disappear from the compose file" and "has this one been restarting".
#
# A first run has no memory and is therefore SILENT on both counts, by design and
# matching changedetection.health: no baseline means no comparison, and inventing one
# would mean the first run after a deploy reports every container as new.
declare -A PREV=()
PREV_KNOWN=0
if [[ -f "$STATE_FILE" ]]; then
    while IFS=$'\t' read -r svc count; do
        [[ -n "$svc" ]] || continue
        PREV["$svc"]="${count//[^0-9]/}"
        PREV_KNOWN=1
    done < "$STATE_FILE"
fi

# --- probe -------------------------------------------------------------------
# Fills FINDINGS with `subject<TAB>state<TAB>detail` lines, and CUR with the restart
# counters this pass observed. Globals rather than a return value because a function
# in $( ) runs in a subshell, where every assignment below would be discarded — the
# same trap that made changedetection.health's watch count silently never persist.
FINDINGS=()
declare -A CUR=()
PROBE_OK=0
FLEET_UP=0
FLEET_TOTAL=0

probe() {
    FINDINGS=()
    CUR=()
    PROBE_OK=0
    FLEET_UP=0
    FLEET_TOTAL=0

    local rc=0 out

    # WHAT SHOULD BE RUNNING comes from the compose file, not from what happens to be
    # running. Asking docker what exists can only ever find containers that exist, so
    # a service that vanished entirely — a `compose down` that half-finished, a
    # watchtower update that removed the old container and failed to create the new —
    # would be invisible to a check built on `docker ps`, and invisible is exactly the
    # failure mode this job exists to close.
    #
    # Without --profile, this correctly EXCLUDES liquidroom-soulseek and
    # liquidroom-roformer: they are `profiles: ["liquidroom"]` and are supposed to be
    # absent between runs. That is the real answer to "which containers are
    # page-worthy" — every service compose declares for the default profile should be
    # up, and the ones deliberately allowed to be down are exactly the ones a profile
    # already marks. A second hand-maintained tier would be a list to forget to update.
    local -a expected=()
    out="$("$DOCKER" compose -f "$COMPOSE_FILE" config --services 2>&1)" || rc=$?
    if (( rc != 0 )) || [[ -z "${out//[[:space:]]/}" ]]; then
        FINDINGS+=("Compose"$'\t'"Unreadable"$'\t'"cannot list services from ${COMPOSE_FILE}: $(head -1 <<<"$out")")
        return 0
    fi
    mapfile -t expected < <(sort <<<"$out")
    # Membership lookup for the CUR guard below; a bash array cannot be searched
    # without a loop and this is consulted once per running container.
    local -A EXPECTED_SET=()
    for svc in "${expected[@]}"; do EXPECTED_SET["$svc"]=1; done

    # Everything docker currently holds for this project, in one call.
    rc=0
    out="$("$DOCKER" ps -a --filter "label=com.docker.compose.project=${PROJECT}" \
                     --format '{{.Names}}' 2>&1)" || rc=$?
    if (( rc != 0 )); then
        # The daemon itself is unreachable. Not a per-container finding — nothing
        # below can be judged — so it is reported as the one fact that matters and
        # the run stops here. Note the alert may well be undeliverable too, since
        # ntfy is itself a container; send_alert turns that into a unit failure, and
        # the journal keeps the diagnosis either way.
        FINDINGS+=("Docker"$'\t'"Not Responding"$'\t'"the daemon did not answer: $(head -1 <<<"$out")")
        return 0
    fi

    local -a names=()
    [[ -n "${out//[[:space:]]/}" ]] && mapfile -t names < <(printf '%s\n' "$out")

    # service -> observed status, health, restart count, start time.
    declare -A STATUS=() HEALTH=() RESTARTS=() STARTED=() CNAME=()
    if (( ${#names[@]} > 0 )); then
        # ONE inspect for the whole fleet. The format is written the long way for a
        # reason that cost a wrong answer to find: `{{.State.Health.Status}}` does not
        # degrade on a container without a healthcheck — it fails the WHOLE format
        # string and emits an empty line. Measured on this box, that silently dropped
        # exactly seven containers, and ntfy was one of them. A monitor whose parser
        # omits the alert channel is the failure this repo hunts, arriving through a
        # template expression.
        while IFS='|' read -r svc cname status health restarts started; do
            [[ -n "$svc" ]] || continue
            STATUS["$svc"]="$status"
            HEALTH["$svc"]="$health"
            RESTARTS["$svc"]="$restarts"
            STARTED["$svc"]="$started"
            CNAME["$svc"]="${cname#/}"
            # ONLY remember a service the compose file still declares. CUR is built
            # from what docker actually holds, `expected` from the DEFAULT-profile
            # services, and those two sets disagree for exactly one kind of thing: a
            # profiled service running transiently. liquidroom's two are profiled
            # precisely because they are allowed to be absent, so a job that starts
            # one, finishes, and lets `--rm` take it away used to leave it in the
            # state file — and the next hourly pass found it remembered, absent from
            # the compose listing, and reported "No Longer Declared". Once per music
            # request, indefinitely; three fired on 2026-08-28 before this.
            #
            # The check it protects still works, because that check is about a
            # service LEAVING the compose file, and a service that was never in the
            # listing cannot leave it.
            if [[ -n "${EXPECTED_SET[$svc]:-}" ]]; then
                CUR["$svc"]="$restarts"
            fi
        done < <("$DOCKER" inspect \
            --format '{{index .Config.Labels "com.docker.compose.service"}}|{{.Name}}|{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.RestartCount}}|{{.State.StartedAt}}' \
            "${names[@]}" 2>/dev/null || true)
    fi

    local now svc label status health started started_epoch age prev delta
    now="$(date +%s)"
    FLEET_TOTAL=${#expected[@]}

    for svc in "${expected[@]}"; do
        # The name on the box, which is what `docker logs` wants and is not always the
        # service name — `postgres` runs as `immich-postgres`, `tailscale` as
        # `tailscaled`. The alert has to name the thing you would go and type.
        label="${CNAME[$svc]:-$svc}"
        status="${STATUS[$svc]:-}"

        if [[ -z "$status" ]]; then
            FINDINGS+=("$label"$'\t'"Missing"$'\t'"declared in compose but no container exists")
            continue
        fi

        if [[ "$status" != "running" ]]; then
            # Title Case for the state slot: exited -> Exited, restarting -> Restarting.
            FINDINGS+=("$label"$'\t'"${status^}"$'\t'"the container is ${status}, not running")
            continue
        fi

        (( FLEET_UP++ )) || true

        health="${HEALTH[$svc]:-none}"
        if [[ "$health" == "unhealthy" ]]; then
            FINDINGS+=("$label"$'\t'"Unhealthy"$'\t'"running, but its own healthcheck is failing")
            continue
        fi

        if [[ "$health" == "starting" ]]; then
            # `starting` is normal for the first minute or two and permanent when a
            # healthcheck can never pass — and permanent `starting` reads as healthy
            # to anything that only asks whether the container is up.
            started="${STARTED[$svc]:-}"
            started_epoch="$(date -d "$started" +%s 2>/dev/null || echo 0)"
            if (( started_epoch > 0 )); then
                age=$(( now - started_epoch ))
                if (( age > HEALTH_START_GRACE )); then
                    FINDINGS+=("$label"$'\t'"Never Healthy"$'\t'"still reporting starting $(( age / 60 ))m after launch, so its healthcheck has never passed")
                    continue
                fi
            fi
        fi

        # A restart counter that MOVED since the previous run. Absolute value says
        # nothing — a container that crashed once six months ago carries a 1 forever —
        # so the delta against what this job last saw is the only reading with meaning.
        prev="${PREV[$svc]:-}"
        if [[ -n "$prev" ]]; then
            delta=$(( ${RESTARTS[$svc]:-0} - prev ))
            if (( delta >= RESTART_LOOP_DELTA )); then
                FINDINGS+=("$label"$'\t'"Restart Looping"$'\t'"restarted ${delta} times since the last check, so it is crashing and being restarted")
            fi
        fi
    done

    # A service that was expected last run and is no longer declared. Usually this is
    # a deliberate compose edit and the alert is a receipt for it; it fires exactly
    # once, because the state file below then forgets the service too. What it really
    # guards is the other case — a broken compose edit that silently narrows what this
    # job watches, which would otherwise shrink the fleet and still report all clear.
    if (( PREV_KNOWN )); then
        local known
        for svc in "${!PREV[@]}"; do
            known=0
            for known_svc in "${expected[@]}"; do
                [[ "$known_svc" == "$svc" ]] && { known=1; break; }
            done
            (( known )) || FINDINGS+=("$svc"$'\t'"No Longer Declared"$'\t'"was expected last run and is not in the compose file now")
        done
    fi

    PROBE_OK=1
    return 0
}

# --- reporting ---------------------------------------------------------------

# report_title <n> <first-finding> -> the fault title.
#
# With exactly one finding the subject is the container, which is the most useful
# thing a lock screen can carry; with more it is a count, because two names is a list
# and three is a paragraph. Same shape as changedetection.health's report_title, and
# the subject is narrower than the `host` topic either way.
report_title() {
    local n="$1" first="${2:-}" subject state
    if (( n == 1 )) && [[ -n "$first" ]]; then
        subject="${first%%$'\t'*}"
        state="${first#*$'\t'}"; state="${state%%$'\t'*}"
        title_state "$subject" "$state"
    else
        title_state Containers "${n} Finding$( (( n == 1 )) || printf s )"
    fi
}

# send_alert <title> <body>
#
# A DROPPED ALERT MUST FAIL THIS UNIT. notify() is best-effort by contract, so its
# SILENCE is the test: curl -fsS prints nothing on success and the error otherwise.
# Without this an ntfy 5xx would leave an hour indistinguishable from a healthy one
# while ExecStartPost= stamped the run fresh for the watchdog — a watcher whose
# failure reads as health, which is the whole reason this job exists.
#
# The journal write is the CALLER's, done before this is reached, so a failed
# delivery still leaves a complete record — and here that matters more than usual,
# because the most likely reason delivery fails is that the thing being reported on
# is ntfy itself.
send_alert() {
    local out
    out="$(fault_open "$CONTAINERS_NTFY_ID" "$1" "$2" 2>&1)"
    if [[ -n "$out" ]]; then
        echo "containers: ntfy publish FAILED, the report above was not delivered: ${out}" >&2
        return 1
    fi
    return 0
}

probe
FIRST=("${FINDINGS[@]:-}")
FIRST_OK=$PROBE_OK

if (( ${#FINDINGS[@]} > 0 )) && [[ -n "${FIRST[0]:-}" ]]; then
    # Second pass — see RECHECK_SECONDS. Only what survives both is real.
    sleep "$RECHECK_SECONDS"
    probe
    CONFIRMED=()
    for f in "${FIRST[@]}"; do
        [[ -n "$f" ]] || continue
        for g in "${FINDINGS[@]:-}"; do
            [[ "$f" == "$g" ]] && { CONFIRMED+=("$f"); break; }
        done
    done
    FINDINGS=("${CONFIRMED[@]:-}")
    # A finding that appeared only in the second pass is deliberately dropped rather
    # than reported: it has not been seen twice, and the next run is an hour away.
    PROBE_OK=$(( FIRST_OK && PROBE_OK ))
fi

# The state file is written only when the probe actually read the fleet. An
# unreachable daemon must not overwrite the remembered restart counters with nothing,
# or the loop detector would be disarmed for a run every time docker hiccups — the
# same reasoning that makes changedetection.health's count write conditional.
if (( PROBE_OK )); then
    if ! { for svc in "${!CUR[@]}"; do printf '%s\t%s\n' "$svc" "${CUR[$svc]}"; done | sort > "$STATE_FILE"; } 2>/dev/null; then
        echo "containers: could not write ${STATE_FILE} — restart-loop detection is disarmed until this is fixed" >&2
    fi
fi

# Silence is the healthy state, matching restic.staleness and smart.sh — no
# OnSuccess chatter, and install.sh refuses one on the monitor class.
REAL=()
for f in "${FINDINGS[@]:-}"; do
    [[ -n "$f" ]] && REAL+=("$f")
done
if (( ${#REAL[@]} == 0 )); then
    # A clean pass closes whatever this job last reported: a container that restarted
    # on its own turns the finding on the phone into "Containers: Running" — the
    # recovery rule (ntfy.lib.sh fault_close). No marker, no message. A lost recovery
    # fails the unit exactly as a lost finding does.
    out="$(fault_close "$CONTAINERS_NTFY_ID" Running "Every expected container is running and healthy." 2>&1)"
    if [[ -n "$out" ]]; then
        echo "containers: ntfy publish FAILED, the recovery was not delivered: ${out}" >&2
        exit 1
    fi
    exit 0
fi

FINDINGS=("${REAL[@]}")
ITEMS=()
for f in "${FINDINGS[@]}"; do
    subject="${f%%$'\t'*}"
    rest="${f#*$'\t'}"
    state="${rest%%$'\t'*}"
    detail="${rest#*$'\t'}"
    ITEMS+=("${subject}"$'\t'"${state}: ${detail}")
done

# --all rather than the five-item cap. A container you cannot see is one you do not
# restart, and there is no button here to make the omission obvious — the same
# reasoning changedetection.health gives for its findings list. A fleet-wide failure
# is the case that produces a long list, and it is the case where every name counts.
FACTS=()
(( FLEET_TOTAL > 0 )) && FACTS+=("${FLEET_UP} of ${FLEET_TOTAL} expected containers running")

TITLE="$(report_title "${#FINDINGS[@]}" "${FINDINGS[0]}")"

# The journal gets everything the alert says, unconditionally and BEFORE the wire.
# It takes the RAW fields rather than the rendered body: a terminal wants tab-separated
# text, not escaped list markers and NBSP indents. Same split as
# changedetection.health, and the same reason — these lines are the only surviving
# record when delivery fails.
printf '%s\n' "$TITLE"
printf '%s\n' "${FINDINGS[@]//$'\t'/ — }"
printf '%s\n' "${FACTS[@]:-}"

send_alert "$TITLE" \
           "$(body_join "$(body_list --all "${ITEMS[@]}")" "$(body_fact "${FACTS[@]:-}")")"
