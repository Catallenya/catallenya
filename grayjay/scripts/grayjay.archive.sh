#!/bin/bash
# grayjay.archive — hand new Grayjay playlist videos to ArchiveBox, and say what became
# of the ones handed over before.
#
# Run daily by grayjay.archive.timer. The work is done by grayjay.archive.py, which
# reports one JSON object; THIS file only turns that report into notifications, so that
# every title in the pipeline is in shell where systemd/contract.sh can read it.
#
# A WORKER, not a reporter (ntfy/MESSAGES.md § 8): when the job could not do its work —
# the backup unreadable, ArchiveBox unreachable — it exits non-zero, so the completion
# stamp is not written and the courier fires beside the fault. A video that failed to
# download is news about the WORLD and exits 0. A notification that could not be
# delivered fails the unit too, the rule host/disk.sh set: notify() is best-effort and
# says nothing on success, so anything it prints is an alert that did not land.

# shellcheck source=grayjay.lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/grayjay.lib.sh"

# Day/time a backup was written, in the owner's time zone. The host runs PDT.
sgt() { TZ=Asia/Singapore date -d "@${1%.*}" '+%a %-d %b, %H:%M'; }

tag_detail() { # $1 = JSON array of tags
    local tags; tags="$(jq -r 'join(", ")' <<<"$1")"
    if [[ "$tags" == *,* ]]; then printf 'Tags: %s' "$tags"; else printf 'Tag: %s' "$tags"; fi
}

publish() { # $1 = path to the JSON report
    local r="$1" n i title body
    local -a items=()
    SEND_ERR="$(mktemp)"

    # --- recoveries: a video you were told had FAILED is now safely in ArchiveBox ---
    # The only good news this pipeline sends (owner, 2026-10-31): a normal save is
    # silent, however many arrive, and the phone hears only about problems. A video that
    # was Dropped or Abandoned and later saves closes its own loop with this.
    n="$(jq '[.archived[] | select(.recovered)] | length' "$r")"
    if (( n > 0 )); then
        items=()
        for (( i = 0; i < n; i++ )); do
            items+=("$(jq -r "[.archived[] | select(.recovered)][$i].title" "$r")"$'\t'"$(tag_detail "$(jq -c "[.archived[] | select(.recovered)][$i].tags" "$r")")")
        done
        if (( n == 1 )); then
            title="$(title_count Archived 1 Video "$(jq -r '[.archived[] | select(.recovered)][0].title' "$r")")"
        else
            title="$(title_count Archived "$n" Video)"
        fi
        body="$(body_join "$(body_list "${items[@]}")" "It failed before and is now saved.")"
        notify_receipt "$title" "$body" 2>>"$SEND_ERR"
    fi

    # --- first failure of a video: said once, then retried quietly ---------------
    n="$(jq '.dropped | length' "$r")"
    if (( n > 0 )); then
        items=()
        for (( i = 0; i < n; i++ )); do
            items+=("$(jq -r ".dropped[$i].title" "$r")"$'\t'"$(jq -r ".dropped[$i].reason" "$r")")
        done
        title="$(title_count Dropped "$n" Video)"
        body="$(body_join "$(body_list "${items[@]}")" "$(body_fact "Retrying daily for 7 days")")"
        notify_fault "$title" "$body" 2>>"$SEND_ERR"
    fi

    # --- 7 days from the first failure: given up ----------------------------------
    n="$(jq '.abandoned | length' "$r")"
    if (( n > 0 )); then
        items=()
        for (( i = 0; i < n; i++ )); do
            items+=("$(jq -r ".abandoned[$i].title" "$r")"$'\t'"$(jq -r ".abandoned[$i].reason" "$r")")
        done
        title="$(title_count Abandoned "$n" Video)"
        body="$(body_join "$(body_list "${items[@]}")" "Retried daily for 7 days.")"
        notify_fault "$title" "$body" 2>>"$SEND_ERR"
    fi

    # The repeating faults below go through fault_open / fault_close (ntfy.lib.sh):
    # each run says whether the fault is present or absent, and one that clears on its
    # own — ArchiveBox back, a fresh backup, a channel listed again — turns its message
    # on the phone into the recovery, the same loop the per-video `Archived` closes.
    # A fault is only CLOSED when this run could actually see the thing.
    local backup_state; backup_state="$(jq -r '.backup.state' "$r")"

    # --- a channel in the Archive group whose videos could not be listed -----------
    # Its videos already tracked are kept as they are (never "removed" on a failed
    # listing) and it is listed again tomorrow. Closed only when the listing works.
    # Skipped entirely while ArchiveBox is unreachable: the listing runs inside its
    # container, so every channel "fails" with it, and one outage would buzz once per
    # channel and blame the channels. `ArchiveBox: Unreachable` below says it once.
    local chid url err channels=.channels[]
    [[ "$(jq -r '.archivebox' "$r")" == "unreachable" ]] && channels=empty
    while IFS=$'\t' read -r chid url err; do
        [[ -n "$chid" ]] || continue
        title="$(title_state Channel Unreadable)"
        body="$(body_join "$(body_fact "$err")" "Could not list the videos of ${url}. Its videos are kept as they are and it is tried again tomorrow.")"
        fault_open "${CHANNEL_NTFY_PREFIX}${chid}" "$title" "$body" 2>>"$SEND_ERR"
    done < <(jq -r "${channels}"' | select(.state == "unreadable") | [.id, .url, .error] | @tsv' "$r")
    while IFS= read -r chid; do
        fault_close "${CHANNEL_NTFY_PREFIX}${chid}" Readable "Its videos are listed again." 2>>"$SEND_ERR"
    done < <(jq -r "${channels}"' | select(.state == "ok") | .id' "$r")

    # --- the backup itself: unreadable, or too old ---------------------------------
    local newest age last=""
    newest="$(jq -r '.backup.newest // empty' "$r")"
    age="$(jq -r '.backup.age_days // empty' "$r")"
    [[ -n "$newest" ]] && last="Last backup $(sgt "$newest")"
    if [[ "$backup_state" == "unreadable" ]]; then
        title="$(title_state Backup Unreadable)"
        if [[ -z "$newest" ]]; then
            body="No backup file exists in master/config. Grayjay may have stopped writing one, or written it somewhere else."
        else
            body="$(body_join "$(body_fact "$last")" \
                "GrayjayBackup.ezip could not be opened. The backup format may have changed.")"
        fi
        fault_open "$BACKUP_NTFY_ID" "$title" "$body" 2>>"$SEND_ERR"
    elif [[ "$(jq -r '.backup.stale' "$r")" == "true" ]]; then
        title="$(title_state Backup "${age} Days Old")"
        body="$(body_join "$(body_fact "$last")" "Open Grayjay on the phone to trigger one.")"
        fault_open "$BACKUP_NTFY_ID" "$title" "$body" 2>>"$SEND_ERR"
    else
        fault_close "$BACKUP_NTFY_ID" Current "A fresh backup has arrived and opens." 2>>"$SEND_ERR"
    fi

    # --- ArchiveBox could not be asked, or refused the hand-over --------------------
    if [[ "$(jq -r '.archivebox' "$r")" == "unreachable" ]]; then
        local waiting err
        waiting="$(jq -r '.not_handed // 0' "$r")"
        err="$(jq -r '.archivebox_error' "$r")"
        title="$(title_state ArchiveBox Unreachable)"
        body="$(body_join "$(body_fact "$err")" \
            "$( (( waiting > 0 )) && printf '%s new videos were not handed over. ' "$waiting")Everything is tried again tomorrow.")"
        fault_open "$ARCHIVEBOX_NTFY_ID" "$title" "$body" 2>>"$SEND_ERR"
    else
        fault_close "$ARCHIVEBOX_NTFY_ID" Reachable "Everything that was waiting is handed over again." 2>>"$SEND_ERR"
    fi

    if [[ -s "$SEND_ERR" ]]; then
        log "ntfy publish FAILED, at least one notification above was not delivered: $(tr '\n' ' ' < "$SEND_ERR")"
        rm -f "$SEND_ERR"
        return 1
    fi
    rm -f "$SEND_ERR"
    return 0
}

main() {
    mkdir -p "$GRAYJAY_STATE" || { log "cannot create ${GRAYJAY_STATE}"; return 1; }
    exec 9>"${GRAYJAY_STATE}/.lock"
    if ! flock -n 9; then
        log "another run holds the lock; nothing to do"
        return 0
    fi

    local report rc=0
    report="$(mktemp)"
    GRAYJAY_MARKER="$GRAYJAY_MARKER" GRAYJAY_GROUP="$GRAYJAY_GROUP" GRAYJAY_YTDLP="$GRAYJAY_YTDLP" \
    GRAYJAY_BACKUP="$GRAYJAY_BACKUP" \
    GRAYJAY_STATE="$GRAYJAY_STATE" GRAYJAY_DOCKER="$GRAYJAY_DOCKER" \
        python3 -I "$CORE" > "$report" || rc=$?
    if (( rc != 0 && rc != 2 )) || ! jq -e . "$report" >/dev/null 2>&1; then
        log "grayjay.archive.py crashed (exit ${rc}); nothing was notified"
        rm -f "$report"
        return 1
    fi

    # The journal line, and the body the courier quotes if this run fails.
    jq -r '"grayjay: backup \(.backup.state)"
           + ", \(.handed) handed over, \(.retried) retried, \(.archived|length) archived"
           + ", \(.dropped|length) dropped, \(.abandoned|length) abandoned"
           + ", \(.adopted) adopted, \(.backfilled // 0) backfilled, \(.pending) pending"
           + ", \(.removed) removed, \(.readded) added back"
           + ", archivebox \(.archivebox)"
           + "; following \(.followed | join(" "))"
           + (if (.channels | map(select(.state != "ok")) | length) > 0 then
                "; channel unreadable: \(.channels | map(select(.state != "ok") | .id) | join(" "))"
              else "" end)' "$report"

    publish "$report" || rc=1
    rm -f "$report"
    return "$rc"
}

[[ "${BASH_SOURCE[0]}" == "$0" ]] && { main "$@"; exit $?; }
return 0
