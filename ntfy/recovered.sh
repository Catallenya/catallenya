#!/usr/bin/env bash
# recovered.sh <unit-name> — after a SUCCESSFUL run, say so if the last one failed.
#
# Run by systemd/policy/10-base.conf as `ExecStartPost=-…/recovered.sh %N`, so every
# job inherits it and none has to remember it. ExecStartPost= runs only when ExecStart
# succeeded, which is exactly "this run worked"; the `-` prefix means nothing here can
# fail the job it rides on.
#
# THE RECOVERY RULE (owner, 2026-10-31): a failure you were told about that then heals
# without you announces that it has. When a job fails, the courier (system-ntfy.sh)
# publishes "<Job>: Failed" under the sequence id `unit-<name>` and leaves a marker
# holding the topic and subject it used. The first successful run after that finds the
# marker, publishes "<Job>: Recovered" on the same id — so the failure on the phone is
# overwritten in place rather than joined by a second message — and removes it.
#
# THE COMMON CASE COSTS ONE stat(). This runs after every successful run of every job,
# including the hourly ones, so the marker test comes before anything is sourced.
#
# NTFY_FAULT_DIR is the test seam, honoured exactly as ntfy.lib.sh and the courier
# honour it: a muted run with no seam set touches nothing.
set -uo pipefail

unit="${1:-}"
[[ -n "$unit" ]] || exit 0

dir="${NTFY_FAULT_DIR:-}"
if [[ -z "$dir" ]]; then
    [[ "${NTFY_DISABLE:-}" == "1" ]] && exit 0
    dir="/zpool/catallenya/systemd/state/.faults"
fi
marker="${dir}/unit-$(tr -cd 'A-Za-z0-9._-' <<<"$unit" | sed 's/^\.*//')"
[[ -f "$marker" ]] || exit 0

# 2>/dev/null BEFORE the input redirection: redirections apply left to right, so the
# other order would print bash's own "cannot open" error if the marker exists but
# cannot be read.
since="" topic="" subject="" routed="" saved=""
saved="$(cat "$marker" 2>/dev/null)" || true
{ read -r since; read -r topic; read -r subject; read -r routed; } 2>/dev/null < "$marker" || true
[[ -n "$topic" && -n "$subject" ]] || { rm -f "$marker" 2>/dev/null; exit 0; }
[[ "$since" =~ ^[0-9]+$ ]] || since="$(date +%s)"

# THE DELETE COMES FIRST AND GATES THE PUBLISH. A job that can read the marker but not
# delete it — a bounded-root unit without CAP_DAC_OVERRIDE — would otherwise announce
# "Recovered" after every successful run, forever. Better it never says so than says
# so every hour; the journal line below is how that shows.
if ! rm -f "$marker" 2>/dev/null || [[ -e "$marker" ]]; then
    echo "recovered.sh: cannot remove ${marker}; not announcing a recovery that would repeat every run" >&2
    exit 0
fi

# shellcheck source=/zpool/catallenya/ntfy/ntfy.lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/ntfy.lib.sh"
# shellcheck disable=SC2034  # read by notify() in ntfy.lib.sh
NTFY_TOPIC="$topic"

# The routed note is the courier's `[topic]` suffix for a job whose own topic nobody
# subscribes to. It rides into title_state's mark slot so the recovery reads exactly
# like the failure it replaces: "Sync: Failed [filmhouse]" -> "Sync: Recovered [filmhouse]".
routed="${routed# }"
# notify() is best-effort and swallows its own failure, but speaks on stderr when the
# publish fails (curl -fsS). A recovery that did not land PUTS THE MARKER BACK, so the
# next successful run tries again rather than leaving "Failed" on the phone for good.
# A muted run has nothing to deliver and counts as delivered.
out="$(notify "$(title_state "$subject" Recovered "$routed")" \
    "$(body_fact "Failed $(TZ=Asia/Singapore date -d "@${since}" '+%a %-d %b, %H:%M')" \
                 "The next run succeeded")" \
    "" "unit-$(tr -cd 'A-Za-z0-9._-' <<<"$unit" | sed 's/^\.*//')" 2>&1)"
if [[ -n "$out" ]] && ! ntfy_muted; then
    printf '%s\n' "$saved" > "$marker" 2>/dev/null || true
    echo "recovered.sh: the recovery for ${unit} was not delivered; will retry on the next successful run: ${out}" >&2
fi
exit 0
