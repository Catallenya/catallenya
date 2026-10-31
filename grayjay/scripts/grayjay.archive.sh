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
        body="$(body_join "$(body_list "${items[@]}")" \
            "Retried daily for 7 days. Take it out of the playlist and put it back to try again.")"
        notify_fault "$title" "$body" 2>>"$SEND_ERR"
    fi

    # --- an allow-listed playlist is not in the backup -----------------------------
    local tag uuid
    while IFS=$'\t' read -r tag uuid; do
        [[ -n "$tag" ]] || continue
        title="$(title_state "$tag" Missing)"
        body="Playlist ${uuid} is not in the latest backup. If it was deleted and made again, put its new id in grayjay/scripts/grayjay.lib.sh."
        notify_fault "$title" "$body" "${MISSING_NTFY_PREFIX}${tag}" 2>>"$SEND_ERR"
    done < <(jq -r '.missing[] | [.tag, .uuid] | @tsv' "$r")

    # --- the backup itself: unreadable, or too old ---------------------------------
    local newest age last=""
    newest="$(jq -r '.backup.newest // empty' "$r")"
    age="$(jq -r '.backup.age_days // empty' "$r")"
    [[ -n "$newest" ]] && last="Last backup $(sgt "$newest")"
    if [[ "$(jq -r '.backup.state' "$r")" == "unreadable" ]]; then
        title="$(title_state Backup Unreadable)"
        if [[ -z "$newest" ]]; then
            body="No backup file exists in master/config. Grayjay may have stopped writing one, or written it somewhere else."
        else
            body="$(body_join "$(body_fact "$last")" \
                "Neither GrayjayBackup.ezip nor its .old copy could be opened. The backup format may have changed.")"
        fi
        notify_fault "$title" "$body" "$BACKUP_NTFY_ID" 2>>"$SEND_ERR"
    elif [[ "$(jq -r '.backup.stale' "$r")" == "true" ]]; then
        title="$(title_state Backup "${age} Days Old")"
        body="$(body_join "$(body_fact "$last")" "Open Grayjay on the phone to trigger one.")"
        notify_fault "$title" "$body" "$BACKUP_NTFY_ID" 2>>"$SEND_ERR"
    fi

    # --- ArchiveBox could not be asked, or refused the hand-over --------------------
    if [[ "$(jq -r '.archivebox' "$r")" == "unreachable" ]]; then
        local waiting err
        waiting="$(jq -r '.not_handed // 0' "$r")"
        err="$(jq -r '.archivebox_error' "$r")"
        title="$(title_state ArchiveBox Unreachable)"
        body="$(body_join "$(body_fact "$err")" \
            "$( (( waiting > 0 )) && printf '%s new videos were not handed over. ' "$waiting")Everything is tried again tomorrow.")"
        notify_fault "$title" "$body" "$ARCHIVEBOX_NTFY_ID" 2>>"$SEND_ERR"
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
    GRAYJAY_PLAYLISTS="${PLAYLISTS[*]}" GRAYJAY_BACKUP="$GRAYJAY_BACKUP" \
    GRAYJAY_STATE="$GRAYJAY_STATE" GRAYJAY_DOCKER="$GRAYJAY_DOCKER" \
        python3 -I "$CORE" > "$report" || rc=$?
    if (( rc != 0 && rc != 2 )) || ! jq -e . "$report" >/dev/null 2>&1; then
        log "grayjay.archive.py crashed (exit ${rc}); nothing was notified"
        rm -f "$report"
        return 1
    fi

    # The journal line, and the body the courier quotes if this run fails.
    jq -r '"grayjay: backup \(.backup.state)\(if .backup.used == "old" then " (from .old)" else "" end)"
           + ", \(.handed) handed over, \(.retried) retried, \(.archived|length) archived"
           + ", \(.dropped|length) dropped, \(.abandoned|length) abandoned"
           + ", \(.adopted) adopted, \(.pending) pending"
           + ", \(.removed) removed, \(.readded) added back"
           + ", archivebox \(.archivebox)"' "$report"

    publish "$report" || rc=1
    rm -f "$report"
    return "$rc"
}

[[ "${BASH_SOURCE[0]}" == "$0" ]] && { main "$@"; exit $?; }
return 0
