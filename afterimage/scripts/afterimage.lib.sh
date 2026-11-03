#!/usr/bin/env bash
# shellcheck disable=SC2034  # config vars are consumed by the scripts that source this
# Shared helpers for the capture triage. Sourced, never executed.
#
# Layout mirrors pigeonhole.lib.sh: config at the top, .env sourced at call time
# (it is runtime-only and not in the repo), ntfy addressed through the tailnet
# Caddy URL rather than a container name or a hardcoded IP.
#
# Everything that talks to api.anthropic.com now lives in ai.lib.sh, shared with
# pigeonhole — api_post/api_class (transport + retry), image_mime/image_ext,
# ai_build_request and ai_extract. Sourced FIRST, before the log()/die() below, so
# this file's identical definitions stay authoritative. Do not re-add a local copy
# of any of it: capture's was the copy, and the divergence risk is the whole point.
# shellcheck source=/zpool/catallenya/ai/scripts/ai.lib.sh
source "/zpool/catallenya/ai/scripts/ai.lib.sh"
# shellcheck source=/zpool/catallenya/ntfy/ntfy.lib.sh
source "/zpool/catallenya/ntfy/ntfy.lib.sh"

# --- notification vocabulary -------------------------------------------------
# Declared here, never in a central table: this is the same shape as a unit's
# [X-Catallenya] Class= sticker — the thing declares, and nothing repeats it in a map
# somebody has to remember to extend. A central verb list would be the SUBSCRIBED
# list again, which silently ate four units' alerts before it was derived instead.
#
# systemd/contract.sh reads these: a title's verb must be in NTFY_MODEL_VERBS or here,
# and every entry must be a past participle. See ntfy/MESSAGES.md.
#
# TWO NOUNS, and the pipeline STAGE decides which: Screenshot until the model has
# produced events, Event afterwards. `Passed: 3 Screenshots` would be a lie — three
# events came from one screenshot. `File` is neither: it is what the *.png glob cannot
# see, which is why it is stranded rather than skipped.
# shellcheck disable=SC2034  # consumed by systemd/contract.sh
NTFY_VERBS=(Stuck Unlinked Skipped Passed Stranded Flagged Abandoned)
# shellcheck disable=SC2034  # consumed by systemd/contract.sh
NTFY_NOUNS=(Screenshot Event File)

AFTERIMAGE_DIR="/zpool/catallenya/afterimage"
# THE SPOOL IS OVERRIDABLE, the scripts are not. Added 2026-08-24 for issue #18, and
# the split is the point: SCRIPT_DIR below still resolves to the real scripts, so
# render_ics.py is always the committed one, while the data spool can be pointed at a
# scratch tree. Same seam and same rule as DOCS in pigeonhole.lib.sh — exercised by
# the suite, NEVER set in production.
#
# It exists because #18 could not be tested without it. The afterimage suite ran 313
# cases and executed ZERO scripts: every one of its 47 sweep assertions greps the
# source for a string. That is why a sweep which exits 0 no matter what survived from
# the pipeline's first commit — you cannot catch a runtime behaviour by reading text,
# and a suite that only reads text will keep reporting green while the thing it
# describes does nothing.
DATA_DIR="${AFTERIMAGE_DATA_DIR:-${AFTERIMAGE_DIR}/data}"
IN_DIR="${DATA_DIR}/incoming"
PENDING_DIR="${DATA_DIR}/pending"
# Every capture ends here once resolved — accepted, rejected, or ignored — with the
# screenshot, the model's proposal and the recorded verdict side by side. That triple
# is a labelled EVAL example — not training data: these models cannot be fine-tuned
# here, so its uses are replaying a new model against recorded verdicts, iterating
# the prompt against real failures, and few-shot examples. Exactly the shape of the
# golden set used for the 2026-07-24 bake-off, but accumulating on its own.
ARCHIVE_DIR="${DATA_DIR}/archive"
# There is no ledger and no recording mode any more (retired 2026-08-01, with the
# documents convergence). State is LOCATIONS ONLY — incoming -> pending -> archive —
# and each archived record carries its own decision.json, so any ledger-style
# question is a jq over archive/*/decision.json. The mode machinery existed to
# protect a production accept-rate metric that was never actually consulted; old
# records keep their `mode` files and fields, which nothing reads.
SCRIPT_DIR="${AFTERIMAGE_DIR}/scripts"

NTFY_TOPIC="afterimage"
# One paused message per topic, not one per screenshot: a stable literal, so each run
# retracts the previous and republishes with the current count instead of stacking.
PAUSED_NTFY_ID="afterimage-paused"
# Same reasoning, for the alarm raised when a screenshot cannot be moved out of
# incoming/. That one re-fires on EVERY trigger — and PathExistsGlob re-fires as long
# as the file is there, so a full pool bought twelve identical notifications before
# systemd gave up. A stable id makes the twelfth replace the first.
STUCK_NTFY_ID="afterimage-stuck"

# Same again for the stray report. The sweep runs NIGHTLY and lists whatever the
# *.png glob cannot see, so a file the pipeline will never pick up produced a fresh
# notification every night for as long as it sat there — a fortnight away from home
# meant fourteen identical messages about the same file. A stable id makes it one.
#
# It does NOT self-clear when the spool goes quiet: a fault has no buttons, and a
# notification without buttons is never withdrawn by the system. See ntfy/MESSAGES.md
# — an absent message is ambiguous, a stale one is not.
STRANDED_NTFY_ID="afterimage-stranded"
# Model + effort come from ai.lib.sh (AI_MODEL / AI_EFFORT), shared with the
# documents pipeline — one edit there moves both.
# Output ceiling for one triage call. Adaptive thinking counts against this, and a
# festival page fanning out to MAX_EVENTS_PER_CAPTURE entries is the widest reply the
# schema can produce. Truncation surfaces as stop_reason=max_tokens, which ai_extract
# rejects rather than handing a half-parsed proposal downstream.
MAX_TOKENS=4096
EVENT_TZ="Asia/Singapore" # fallback when the screenshot gives no timezone clue
DURATION_MIN=60           # default length when only a start time is known
# Everything here stays LOCAL: capture/ is deliberately absent from restic's path
# allowlist, so nothing is copied off-box. ZFS + sanoid still cover disk failure
# and rollback. Do NOT add capture/ to restic without revisiting that decision — a
# screenshot can contain anything that was on screen.
# A festival page can list a dozen acts, and each becomes its own notification, so
# this bounds the ping storm. Raised from 4 on 2026-07-27: a real Esplanade day
# listing had six and two were dropped. Truncating is now logged and surfaced in the
# notification body — silently discarding a user's events is worse than a few pings.
MAX_EVENTS_PER_CAPTURE=8
# MEMORY. One file the triage reads before every screenshot and adds a note to after
# it, so a screenshot that leaves something out ("Sun 2pm, 45 Dunearn Rd") can be read
# against the ones before it (three house viewings this fortnight). Each note is one
# sentence the MODEL writes about what the screenshot said of the owner's plans, or
# nothing at all for an accidental capture, a meme or a receipt. Notes are trimmed on
# every write, by count and by age, so the file never grows and old themes fade on
# their own. 30 notes is about a month at the measured rate (31 captures in the month
# to 2026-10-15), so the two limits arrive together; each note costs ~50 input tokens.
#
# The tap is NOT written here — it happens later, in the container, which never
# touches this file. Each note keeps the ids of the records its screenshot became, and
# memory_render looks each one up in archive/ or pending/ when the NEXT screenshot
# arrives, so it always reads the final decision, a correction inside the 120s window
# included.
#
# Lives in data/, so like every screenshot it is never copied off-box (see above).
MEMORY_FILE="${DATA_DIR}/memory.jsonl"
MEMORY_MAX_NOTES=30
MEMORY_MAX_DAYS=30
# A note is derived from a screenshot, and a screenshot is untrusted: whatever text it
# plants in a note rides into every prompt for a month. The cap bounds that, and the
# prompt labels the block as content, never instructions.
MEMORY_NOTE_MAX=300
# Longest button label. ntfy imposes no limit of its own — 9, 17, 22 and 43
# characters were all accepted with HTTP 200 when tested on 2026-07-28 — so this
# is purely about phone width with three buttons in a row. 12 was the old value
# and truncated "Esplanade Concert Hall" to the mid-word "Esplanade Co", which
# read as a bug. Labels now cut back to a word boundary rather than mid-word, so
# raising this only ever adds whole words.
BUTTON_LABEL_MAX=20
# Separator between an event's detail and the alternative on offer. The word "or"
# used to sit here ("19:15  ·  or 20:15"); the bullet alone says the same thing in
# a line that has to survive a phone's wrapping.
# " / ", and the history matters because this has moved twice.
#
# It was " or " until 2026-07-27 (8ede8b7), when reading real notifications ON A PHONE
# showed the word costing width in a line that has to survive wrapping on a narrow
# screen. It became " • ".
#
# It moved again on 2026-08-22, when the fact marker became " • " too — and then the
# proposal read `• 19:30 - 21:00 • 20:15`: three bullets on one line meaning two
# different things. " / " keeps the width that 8ede8b7 was about and reads as a
# choice without spelling it. Do not restore " • " without moving the fact marker.
ALT_SEP=" / "
RENOTIFY_AFTER_HOURS=24   # one nudge, in case the first ntfy was never seen
IGNORE_AFTER_HOURS=168    # 7 days untouched -> archive with outcome "ignored"

# Screenshot retention. Discard does not delete, so every capture accumulates —
# and a screenshot can hold anything that was on screen. After this many days the
# IMAGE is deleted from an archived record, whatever its outcome (7, was 90 — and
# the 90 never ran: the sweep exited early on an empty pending/ before reaching
# the prune, so nothing was ever pruned). The proposal, the rendered .ics, the
# context and the verdict stay forever: small, text-only, and they carry the
# analysis value. The old carve-out that kept failure-case images indefinitely
# retired with the ledger — a week is long enough to look at a case the model got
# wrong, and a screenshot is the sensitive half of the record.
# 0 disables pruning entirely.
PRUNE_IMAGE_AFTER_DAYS=7

# How far back the sweep's retract pass reaches into archive/. Anything resolved
# longer ago than this is marked as handled without a DELETE being sent: its
# notification has long since aged out of the phone, so the call would be a no-op
# event in the topic. Exists only to bound the FIRST run after this shipped, which
# would otherwise have swept every record ever archived.
RETRACT_WITHIN_DAYS=14

# A 24-hour HH:MM, anchored, with the hour and minute ranges spelled out — a loose
# [0-9]{2}:[0-9]{2} admits "24:00" and "19:99", and both reach render_ics.py as a
# time that does not exist.
#
# ONE definition, because the two readers must never disagree about what a time IS.
# validate_proposal refuses a proposal whose start_time does not match this, and
# button_label prints a bare HH:MM as the button only when it does. While the pattern
# sat in four places, a tightening in the gate and not in the label — or the reverse —
# would have put a refused time on a button, or sent a perfectly good one to the
# generic "All day". Both are silent, and both are about the one line the owner reads
# before tapping.
HHMM_RE='^([01][0-9]|2[0-3]):[0-5][0-9]$'

# API_MAX_ATTEMPTS / API_RETRY_BASE_S / API_URL and image_mime / image_ext moved to
# ai.lib.sh (sourced at the top). Transient-failure policy is unchanged: the record
# is left in pending/ without a proposal.json and the sweep re-queues the screenshot
# once before giving up.

# is_heic <file> — true for a HEIC/HEIF image, by content. Camera photos from an
# iPhone (and Android phones set to "high efficiency") are HEIC, which the API does
# not accept, so the triage converts them before anything else reads the record.
# The format is an ISO-BMFF box: bytes 4-7 are `ftyp`, 8-11 the major brand. AVIF
# shares the container under its own brands and is deliberately not matched here.
is_heic() {
    case "$(LC_ALL=C head -c 12 "$1" 2>/dev/null | tail -c 8)" in
        ftypheic|ftypheix|ftypheim|ftypheis|ftyphevc|ftyphevx|ftypmif1|ftypmsf1) return 0 ;;
    esac
    return 1
}

# heic_to_jpeg <in> <out> — decode via ImageMagick's libheif delegate. -auto-orient
# bakes the camera's rotation into the pixels, since the JPEG carries no orientation
# the model would honour. The resize only ever shrinks: a 12 MP photo at full size
# lands near the API's 5 MB per-image ceiling, and nothing on a poster or a sign
# needs more than 2576 px on its long edge to be read.
heic_to_jpeg() {
    convert "$1" -auto-orient -resize '2576x2576>' -quality 90 "jpeg:$2"
}

# diff_axis <this-event-json> <other-event-json> -> year|date|time|venue|none
# Which single thing distinguishes two ways of attending the same event. Both the
# button labels and the notification body read this, so they can never disagree
# about what is being chosen — the body used to state "Wednesday, 31 March 2027" as
# settled while the buttons offered [31 Mar] [1 Apr].
diff_axis() {
    local a="$1" b="$2" ad bd at bt al bl
    ad="$(jq -r '.date // ""' <<<"$a")"; bd="$(jq -r '.date // ""' <<<"$b")"
    [[ "${ad%%-*}" != "${bd%%-*}" ]] && { echo year;  return; }
    [[ "$ad" != "$bd" ]]              && { echo date;  return; }
    at="$(jq -r '.start_time // ""' <<<"$a")"; bt="$(jq -r '.start_time // ""' <<<"$b")"
    [[ "$at" != "$bt" ]]              && { echo time;  return; }
    al="$(jq -r '.location // ""' <<<"$a")";   bl="$(jq -r '.location // ""' <<<"$b")"
    [[ -n "$al" && "$al" != "$bl" ]]  && { echo venue; return; }
    echo none
}

# button_label <this-event-json> <other-event-json> -> short button text
# Labels the axis that actually DIFFERS between the two choices, so a pair always
# reads as a comparison rather than two unrelated facts:
#
#   two showtimes      [19:15]     [20:15]
#   a run over 2 days  [30 Jul]    [31 Jul]
#   two years          [15 Nov 26] [15 Nov 27]
#   two venues         [Esplanade] [TOMATILLO]
#
# Symmetric by construction: each side is told about the other, so the primary can
# never show its time while the alternative shows a date. Pass the same object twice
# when there is no alternative — a lone button then says the time, which is right.
#
# Nothing here comes from the model: it used to name the alternative itself, and its
# prompt examples were 12-hour while the primary is forced to 24-hour, which is how a
# notification came to read "19:00" beside "8.15pm".
button_label() {
    local a="$1" b="$2" at v sd ed
    at="$(jq -r '.start_time // ""' <<<"$a")"
    case "$(diff_axis "$a" "$b")" in
        year)  date -d "$(jq -r '.date' <<<"$a")" '+%-d %b %y' 2>/dev/null || printf 'Alternative' ;;
        date)  date -d "$(jq -r '.date' <<<"$a")" '+%-d %b'    2>/dev/null || printf 'Alternative' ;;
        time)
            if [[ "$at" =~ $HHMM_RE ]]; then printf '%s' "$at"
            else printf 'All day'; fi ;;
        venue)
            # Strip to the Actions-header charset before truncating, so a venue with
            # a comma shortens rather than failing the whitelist outright.
            v="$(jq -r '.location' <<<"$a" | tr -cd 'A-Za-z0-9 :.-')"
            if (( ${#v} > BUTTON_LABEL_MAX )); then
                # Cut back to a WORD boundary. A hard cut produced "Esplanade Co",
                # which reads as a rendering fault rather than an abbreviation.
                # A single word longer than the cap still has to be chopped.
                if [[ "${v:BUTTON_LABEL_MAX:1}" == " " ]]; then
                    v="${v:0:BUTTON_LABEL_MAX}"
                else
                    v="${v:0:BUTTON_LABEL_MAX}"
                    [[ "$v" == *" "* ]] && v="${v% *}"
                fi
            fi
            printf '%s' "$(sed 's/ *$//' <<<"$v")" ;;
        *)
            # A SPAN labels its range. "All day" on a two-day market says nothing
            # about the second day, and the range is the whole point of end_date.
            sd="$(jq -r '.date' <<<"$a")"; ed="$(jq -r '.end_date // ""' <<<"$a")"
            if [[ -n "$ed" && "$ed" != "null" && "$ed" != "$sd" ]]; then
                if [[ "$(date -d "$sd" '+%m' 2>/dev/null)" == "$(date -d "$ed" '+%m' 2>/dev/null)" ]]; then
                    printf '%s-%s' "$(date -d "$sd" '+%-d' 2>/dev/null)" \
                                   "$(date -d "$ed" '+%-d %b' 2>/dev/null)"
                else
                    # Crosses a month, so both halves need their month naming.
                    printf '%s-%s' "$(date -d "$sd" '+%-d %b' 2>/dev/null)" \
                                   "$(date -d "$ed" '+%-d %b' 2>/dev/null)"
                fi
            elif [[ "$(jq -r '.all_day' <<<"$a")" == "true" || -z "$at" || "$at" == "null" ]]; then
                printf 'All day'
            elif [[ "$at" =~ $HHMM_RE ]]; then printf '%s' "$at"
            else printf 'Alternative'; fi ;;
    esac
}

# safe_label <this-event-json> <other-event-json> <fallback>
# button_label's answer, guaranteed to survive the Actions header. The label is
# spliced into a comma-and-semicolon separated list, so a stray comma or CRLF would
# silently splice a button of its own; anything outside the whitelist is replaced
# with the caller's generic word instead.
#
# The length bound must track BUTTON_LABEL_MAX, and this is now the ONE place it
# does. When the two drifted apart — the cap was raised and the regex was not — a
# longer label silently became the generic "Add" instead of the venue it had just
# been trimmed to.
safe_label() {
    local l
    l="$(button_label "$1" "$2")"
    [[ "$l" =~ ^[A-Za-z0-9\ :.-]{1,${BUTTON_LABEL_MAX}}$ ]] || l="$3"
    printf '%s' "$l"
}

# capture_actions <base-url> <record-id> <primary-label> [alt-label]
# The ntfy Actions string: [primary] [alternative] [Discard]. An empty alt label
# means there is no alternative and the middle button is simply absent.
#
# ONE definition, because the sweep's nudge had its own — hardcoded to "Add" and
# "Discard" — which dropped the Alternative button on every nudge while
# event.alt.ics was still on disk and the ?alt=1 route still live. The nudge
# retracts the original message, so tapping the alternative stopped being possible
# at all: the button was not merely absent, it was withdrawn.
#
# X-Afterimage is not authentication. It forces a CORS preflight, which the
# container answers for exactly one origin, so a page open on a tailnet device
# cannot fire a callback it scraped off the (unauthenticated) topic.
# discard_action <base> <id> — the Discard button on its own.
#
# Extracted so the needs-a-human path and capture_actions() build the same URL from
# the same place. A needs-a-human record has NO proposal.json, so `Add` is impossible
# — but Discard is only an archive, which the container's /drop route already does for
# any pending record, proposal or not.
#
# Giving that record its one real button is what puts it back under the withdrawal
# rule: it can now be cleared by a tap, and if it is ignored the archive backstop
# withdraws a control that has genuinely gone dead. Before this it was the single
# button-less message in the repo that the system removed anyway, silently, at 7 days.
discard_action() {
    printf 'http, Discard, %s/afterimage/%s/drop, method=POST, headers.X-Afterimage=1' "$1" "$2"
}

capture_actions() {
    local base="$1" id="$2" primary="$3" alt="${4:-}" a
    a="http, ${primary}, ${base}/afterimage/${id}/add, method=POST, headers.X-Afterimage=1"
    [[ -n "$alt" ]] && \
        a+="; http, ${alt}, ${base}/afterimage/${id}/add?alt=1, method=POST, headers.X-Afterimage=1"
    a+="; $(discard_action "$base" "$id")"
    printf '%s' "$a"
}

# record_actions <base-url> <record-id> <record-dir> -> Actions string, non-zero if
# the record carries no proposal.
#
# The same buttons, derived from what is ON DISK rather than from a reply in memory
# — which is all the sweep has, hours or days later. event.alt.ics is the test for
# the alternative because it is the file the ?alt=1 route reads: offering a button
# whose .ics is missing would be a tap that answers 500.
record_actions() {
    local base="$1" id="$2" rec="$3" ev alt
    ev="$(cat "${rec}/proposal.json" 2>/dev/null)" || return 1
    [[ -n "$ev" ]] || return 1
    if [[ -f "${rec}/event.alt.ics" && -f "${rec}/proposal.alt.json" ]]; then
        alt="$(cat "${rec}/proposal.alt.json")"
        capture_actions "$base" "$id" \
            "$(safe_label "$ev" "$alt" Add)" "$(safe_label "$alt" "$ev" Alternative)"
    else
        capture_actions "$base" "$id" "$(safe_label "$ev" "$ev" Add)"
    fi
}

# fork_record <src-record> <dst-record> <ext> <capture-group-id>
# Copy one capture's record into a sibling for another event from the same
# screenshot. The image is HARDLINKED, so N events off one screenshot cost one
# image on disk.
#
# Every sibling must exist before any event is processed: archive_record MOVES the
# record directory, so a failure on the first event once deleted the screenshot the
# remaining events were still being built from, losing the whole capture.
fork_record() {
    local src="$1" dst="$2" ext="$3" group="$4"
    mkdir -p "$dst" || return 1
    ln "${src}/screenshot.${ext}" "${dst}/screenshot.${ext}" 2>/dev/null \
        || cp "${src}/screenshot.${ext}" "${dst}/screenshot.${ext}" || return 1
    # The whole model reply, so any record can answer "what else was on that page".
    cp "${src}/capture.json" "${dst}/capture.json" 2>/dev/null
    jq -c --arg g "$group" '. + {capture_group:$g}' "${src}/context.json" \
        > "${dst}/context.json" 2>/dev/null || cp "${src}/context.json" "${dst}/context.json" 2>/dev/null
    return 0
}

# fan_out_records <capture-id> <capture-record> <ext> <count>
# One record per event from a single screenshot, printed as "<eid>\t<record-dir>":
# ALWAYS <count> lines, ALWAYS in event order. The capture's own record is the first,
# so the screenshot the others are hardlinked from is not the one archive_record moves
# first; every other event gets a sibling.
#
# A line with an EMPTY id is an event whose record could not be created. It is printed
# rather than skipped because the caller pairs these lines with the event list
# POSITIONALLY. A compacting list was the bug: with three events and a failure on the
# second, the third event was written into the second's record and the fourth vanished
# with nothing counted and nothing said — the log even named the wrong casualty.
#
# The half-built directory goes with it. A record with no screenshot and no
# first_failed stamp matches no branch of the sweep, so it would sit in pending/
# forever, invisible to everything including the watchdog.
fan_out_records() {
    local id="$1" rec="$2" ext="$3" n="$4" k eid erec
    for (( k = 0; k < n; k++ )); do
        if (( k == 0 )); then printf '%s\t%s\n' "$id" "$rec"; continue; fi
        eid="$(cat /proc/sys/kernel/random/uuid)"
        erec="${PENDING_DIR}/${eid}"
        if fork_record "$rec" "$erec" "$ext" "$id"; then
            printf '%s\t%s\n' "$eid" "$erec"
        else
            rm -rf "$erec"
            printf '\t\n'
        fi
    done
}

# event_is_past <date> <start_time> <all_day> <now-epoch> -> true when it is over
# Computed here, never asked of the model. An all-day event is past only once its
# whole day has gone; a timed one the moment its start has.
event_is_past() {
    local d="$1" st="$2" ad="$3" now="$4" when
    if [[ "$ad" == "true" || -z "$st" || "$st" == "null" ]]; then
        when="$(TZ="$EVENT_TZ" date -d "${d} 23:59:59" +%s 2>/dev/null)" || return 1
    else
        when="$(TZ="$EVENT_TZ" date -d "${d} ${st}" +%s 2>/dev/null)" || return 1
    fi
    [[ -n "$when" ]] || return 1
    (( when < now ))
}

# api_class / api_post moved to ai.lib.sh (sourced at the top), unchanged.

# How long a parked record waits before the sweep gives up on it, measured from the
# FIRST failure and never from the last attempt. Seven days, the same clock every
# other unresolved thing in this pipeline runs on.
#
# This replaced REQUEUE_AFTER_HOURS=1 and a two-attempt marker. That pair was written
# when the sweep ran hourly, so it meant "wait an hour, try once more, then give up" —
# a sensible rule for a network blip. When the sweep moved morning-side on 2026-08-01
# the schedule changed and the rule did not, so the same code silently became "give up
# after two days", and an outage longer than a weekend destroyed captures that were
# never wrong. The retry is now once per sweep, which is once per day, until this.
PAUSED_GIVE_UP_DAYS=7

# parked_ids <pending-dir> -> the short id of every record waiting on the API
#
# ONE predicate, read by the triage's end-of-run summary and by the sweep, because
# they disagreed: the triage tested proposal.json and the sweep tests capture.json.
# proposal.json is only a PROXY for "did the model answer", and a wrong one — a
# needs-a-human record has no proposal either, because there was no date to render.
# So a capture the model had read and reported on was counted as an outage victim,
# and the paused summary said "2 Screenshots" while one of them was simply waiting
# for the owner.
#
# first_failed is the other half: no stamp means the triage has not finished with the
# record, which is a run in flight rather than something parked.
parked_ids() {
    local dir="$1" p
    for p in "$dir"/*/; do
        # Independent of nullglob, which is set by the scripts and not by this file:
        # an unmatched glob stays literal and simply fails to be a directory.
        [[ -d "$p" ]] || continue
        p="${p%/}"
        [[ -f "${p}/first_failed" ]] || continue
        [[ -f "${p}/capture.json" ]] && continue
        basename "$p" | cut -c1-8
    done
}

# parked_reason <pending-dir> -> the sentence in front of the paused summary
#
# Read from the ${rec}/paused_reason the triage writes at park time, most recent
# park first — NEVER from a variable left over from the triage's own loop. The
# summary is built from every parked record, including ones this run never touched,
# so the leftover reason labelled a week-old billing pause with whatever the last
# screenshot in the batch happened to hit — and on a run where everything SUCCEEDED
# it was `ai_reason 0`, the empty string, which rendered as "Paused: 3 Screenshots …
# . Retrying daily".
#
# The fallback covers records parked before this file existed; anything newer has one.
parked_reason() {
    local dir="$1" f newest="" reason=""
    for f in "$dir"/*/paused_reason; do
        [[ -f "$f" ]] || continue
        [[ -z "$newest" || "$f" -nt "$newest" ]] && newest="$f"
    done
    [[ -n "$newest" ]] && reason="$(cat "$newest")"
    printf '%s' "${reason:-$(ai_reason 2)}"
}

# parked_cause <pending-dir> -> Unpaid | Unreachable | Mixed | ""
#
# The bracketed half of the paused title. Deliberately reads EVERY parked record
# rather than the newest one parked_reason picks: an outage can be both at once —
# the triage rewrites a record's reason on every park, so a spool can hold records
# that failed unreachable beside records that failed unpaid. Naming only the newest
# would hide the other, and the two want different remedies.
parked_cause() {
    local dir="$1" f
    local -a reasons=()
    for f in "$dir"/*/paused_reason; do
        [[ -f "$f" ]] || continue
        reasons+=("$(cat "$f")")
    done
    paused_cause "${reasons[@]:-}"
}

# --- memory -----------------------------------------------------------------
# Best-effort by contract, all three: a memory that cannot be read or written costs the
# next screenshot some context and never costs this one its proposal. Each returns 0.

# _memory_entries -> every well-formed note in the file, one compact object per line
_memory_entries() {
    [[ -f "$MEMORY_FILE" ]] || return 0
    jq -c -R 'fromjson? // empty | select(type == "object" and (.id|type) == "string"
                                         and (.note|type) == "string" and (.at|type) == "number")' \
        "$MEMORY_FILE" 2>/dev/null
}

# _memory_write <jq-filter> [jq args...] — rewrite the file through a filter over the
# slurped entries, then trim. Atomic (temp file + mv), so a crash leaves the old file.
_memory_write() {
    local filter="$1" tmp cutoff; shift
    cutoff=$(( $(date +%s) - MEMORY_MAX_DAYS * 86400 ))
    tmp="$(mktemp "${MEMORY_FILE}.XXXXXX" 2>/dev/null)" || { log "  !! memory: cannot write"; return 0; }
    if _memory_entries | jq -c -s "$@" --argjson cutoff "$cutoff" --argjson max "$MEMORY_MAX_NOTES" \
           "${filter} | map(select(.at >= \$cutoff)) | sort_by(.at) | .[-\$max:] | .[]" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$MEMORY_FILE"
    else
        rm -f "$tmp"; log "  !! memory: update failed, left as it was"
    fi
    return 0
}

# memory_remember <capture-id> <capture-epoch> <capture-local> <note>
# Add this screenshot's note. An empty note — the model saying "nothing worth keeping"
# — writes nothing. A note for an id already present replaces it rather than stacking.
memory_remember() {
    local id="$1" at="$2" local_h="$3" note="$4"
    note="$(printf '%s' "$note" | tr -d '\000-\037\177')"
    note="${note:0:$MEMORY_NOTE_MAX}"
    [[ -n "${note// /}" && "$note" != "null" ]] || return 0
    [[ "$at" =~ ^[0-9]+$ ]] || at="$(date +%s)"
    _memory_write 'map(select(.id != $id)) + [{id:$id, at:$at, at_local:$loc, note:$note, ids:[$id]}]' \
        --arg id "$id" --argjson at "$at" --arg loc "$local_h" --arg note "$note"
}

# memory_link <capture-id> <record-id>... — the records a multi-event screenshot fanned
# out into, so the next render can report every one of its taps.
memory_link() {
    local id="$1"; shift
    (( $# )) || return 0
    _memory_write 'map(if .id == $id then .ids = $ids else . end)' \
        --arg id "$id" --argjson ids "$(printf '%s\n' "$@" | jq -R . | jq -cs 'map(select(. != ""))')"
}

# _record_outcome <record-id> -> added | discarded | waiting | expired | nothing | failed | ""
# What became of one record, read where the record lives NOW. Empty for a record that
# is gone, which says nothing rather than something wrong.
_record_outcome() {
    local id="$1" o=""
    if [[ -f "${ARCHIVE_DIR}/${id}/decision.json" ]]; then
        o="$(jq -r '.outcome // ""' "${ARCHIVE_DIR}/${id}/decision.json" 2>/dev/null)"
    elif [[ -d "${PENDING_DIR}/${id}" ]]; then
        o=pending
    fi
    case "$o" in
        add|add_alt)       echo added ;;
        discard|undone)    echo discarded ;;
        pending)           echo waiting ;;
        ignored)           echo expired ;;
        not_event)         echo nothing ;;
        failed)            echo failed ;;
        *)                 echo "" ;;
    esac
}

# memory_render <exclude-id> -> the notes as prompt lines, oldest first; empty if none
# "- Thu 15 Oct 14:02: <note> (added)". The outcome is looked up per record now, not
# stored, which is the whole reason the tap needs no writer of its own.
memory_render() {
    local exclude="$1" e id at_local note outcomes o tag
    local -A n
    while IFS= read -r e; do
        id="$(jq -r .id <<<"$e")"
        [[ "$id" == "$exclude" ]] && continue
        at_local="$(jq -r '.at_local // ""' <<<"$e")"
        note="$(jq -r .note <<<"$e")"
        n=()
        while IFS= read -r o; do
            o="$(_record_outcome "$o")"
            [[ -n "$o" ]] && n[$o]=$(( ${n[$o]:-0} + 1 ))
        done < <(jq -r '(.ids // [.id])[]' <<<"$e")
        outcomes=""
        for o in added discarded waiting expired nothing failed; do
            [[ -n "${n[$o]:-}" ]] || continue
            case "$o" in
                added)     tag="added by the user" ;;
                discarded) tag="discarded by the user" ;;
                waiting)   tag="not tapped yet" ;;
                expired)   tag="never tapped, expired" ;;
                nothing)   tag="nothing to add" ;;
                failed)    tag="could not be read" ;;
            esac
            (( ${#n[@]} > 1 || n[$o] > 1 )) && tag="${n[$o]} ${tag}"
            outcomes+="${outcomes:+, }${tag}"
        done
        printf -- '- %s: %s%s\n' "$at_local" "$note" "${outcomes:+ (${outcomes})}"
    done < <(_memory_entries)
    return 0
}

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

# Caddy serves ntfy on the tailnet; the URL comes from .env like everything else
# (no hardcoded IP, no docker socket). Returns non-zero if .env is unreadable.
# Only the four keys this pipeline needs, extracted rather than sourced. `source`
# on the root .env pulled in every database credential and service token the stack
# has — roughly forty values, to use four — while the unit file claimed the sandbox
# prevented it. It is also arbitrary code execution if that file ever grows a
# $(...), which a data file should never be able to do.
#
# The EXTRACTION is _ntfy_env's, in ntfy/ntfy.lib.sh; the KEY LIST stays here, and
# that separation is deliberate rather than a half-finished merge. Three pipelines
# needed the same loop over different names, so the loop is shared and the names are
# not: a function holding the union of every pipeline's keys would read as a contract
# nobody wrote. The one key below is this pipeline's own — the port the Add and
# Discard buttons POST back to.
#
# (Deliberately not naming the variables here: gitleaks 8.24.3, which CI pins,
# reads a secret-shaped name beside the word "password" as a finding.)
_load_env() { _ntfy_env AFTERIMAGE_REVERSE_PROXY_PORT; }

# hdr_safe and md_escape live in ntfy/ntfy.lib.sh (sourced at the top). They guard
# the boundary where untrusted text — model output, a synced filename — reaches a
# notification, which is a property of the sink, not of the API that fetched it.

# --- the model-output gate -------------------------------------------------
# Everything the model returns is untrusted: it is derived from a screenshot whose
# contents an attacker may control. It reaches three sinks that each used to defend
# themselves differently (a curl body, an iCalendar TEXT value, the ntfy body the
# user actually reads). These two functions are the single choke point instead —
# run once, immediately after the API call, before any consumer.

# clean_proposal <json> -> json on stdout
# Strip C0 control characters and DEL from every model-authored free-text field, and
# cap length. Control characters are what let a title break out of an iCalendar
# property; the cap keeps an over-long field from crowding out the rest of the body.
clean_proposal() {
    jq -c '
      def clean: if type == "string"
                 then (explode | map(select(. >= 32 and . != 127)) | implode | .[0:500])
                 else . end;
        .reason |= clean
      | .memory |= clean
      | .events = [ .events[]?
                    | .title       |= clean
                    | .location    |= clean
                    # A link is kept WHOLE or dropped, never truncated or stripped
                    # into a different link. Same pattern as render_ics.py, so the
                    # link the notification shows is the one Add writes.
                    | .conference  |= (if type == "string" and test("^https://[!-~]+$")
                                         and length <= 500 then . else null end)
                    | .description |= clean
                    | .alternatives = [ .alternatives[]? | .location |= clean ] ]
    ' <<<"$1"
}

# validate_proposal <json> -> prints a reason code and returns 1 if unusable.
# Mechanical checks only — never the model's own self-assessment.
#
# The structured-output schema constrains SHAPE, not VALUES: date, start_time and
# timezone are plain strings. documents.intake learned this the expensive way — its
# date regex accepted 2023-02-29 and a model emitted exactly that on a paystub,
# twice, which is what commit fa5638e fixed. A strict schema is necessary and not
# sufficient; this is that pipeline's `gate()` applied to the same problem.
validate_proposal() {
    local p="$1" v f

    v="$(jq -r '.date // ""' <<<"$p")"
    [[ "$v" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "BAD_DATE"; return 1; }
    date -d "$v" >/dev/null 2>&1 || { echo "IMPOSSIBLE_DATE"; return 1; }

    # end_date turns an event into a SPAN, so a bad one silently changes how long
    # the entry is rather than failing visibly. An end before the start would make
    # render_ics emit DTEND < DTSTART, which clients display unpredictably.
    local ed; ed="$(jq -r '.end_date // "null"' <<<"$p")"
    if [[ "$ed" != "null" && -n "$ed" ]]; then
        [[ "$ed" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "BAD_END_DATE"; return 1; }
        date -d "$ed" >/dev/null 2>&1 || { echo "IMPOSSIBLE_END_DATE"; return 1; }
        [[ "$ed" < "$v" ]] && { echo "END_BEFORE_START"; return 1; }
    fi

    # HH:MM 24h, or null. An unparseable time used to fall through to an all-day
    # event while the notification still showed "5pm" — the user approved one thing
    # and the calendar got another.
    for f in start_time end_time; do
        v="$(jq -r --arg f "$f" '.[$f] // "null"' <<<"$p")"
        [[ "$v" == "null" ]] && continue
        [[ "$v" =~ $HHMM_RE ]] || { echo "BAD_TIME"; return 1; }
    done

    # The zone must resolve. render_ics.py falls back to EVENT_TZ on an unknown zone,
    # but the notification shows a bare HH:MM with no zone — so a bad value is an
    # invisible time shift on an event the user thinks they verified.
    v="$(jq -r '.timezone // ""' <<<"$p")"
    if [[ -n "$v" ]] && ! python3 -c 'import sys,zoneinfo; zoneinfo.ZoneInfo(sys.argv[1])' "$v" 2>/dev/null; then
        echo "BAD_TIMEZONE"; return 1
    fi

    # The alternative is rendered into a real .ics and written on one tap, so it gets
    # the same checks. An unusable alternative is dropped, not fatal — the primary
    # reading is still good (afterimage.triage.sh falls back to plain Add/Discard).
    if [[ "$(jq -r '.alternatives | length' <<<"$p")" -gt 0 ]]; then
        v="$(jq -r '.alternatives[0].date // ""' <<<"$p")"
        if ! [[ "$v" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || ! date -d "$v" >/dev/null 2>&1; then
            echo "BAD_ALT"; return 1
        fi
        for f in start_time end_time; do
            v="$(jq -r --arg f "$f" '.alternatives[0][$f] // "null"' <<<"$p")"
            [[ "$v" == "null" ]] && continue
            [[ "$v" =~ $HHMM_RE ]] || { echo "BAD_ALT"; return 1; }
        done
    fi
    return 0
}

# triage_route <is_event> <needs_human> <event-count> -> not_event|needs_human|events
# Which branch a model reply belongs in. Pure, and here rather than inline in
# afterimage.triage.sh so the tests assert the REAL mapping instead of a copy of it
# that drifts — same reasoning as api_class.
#
# THE ORDER IS THE WHOLE POINT, and it used to be wrong. The "no events" test ran
# first, so a reply meaning "this needs your attention but I could not build an
# event" — is_event=true, needs_human=true, events=[] — was reported as the quiet
# "No event found" instead of the "Needs a human" warning. A capture asking for
# help was filed as junk. Found 2026-07-28 replaying an archived capture through
# a different model, which emits that shape where opus-5 emits a placeholder
# event alongside; nothing guarantees opus-5 never will.
#
# is_event=false is still decided first: the model saying nothing schedulable is
# here settles the question, and a needs_human beside it is noise.
triage_route() {
    local is_event="$1" needs_human="$2" n="$3"
    [[ "$is_event"    != "true" ]] && { echo not_event;   return; }
    [[ "$needs_human" == "true" ]] && { echo needs_human; return; }
    # A non-numeric count is a malformed reply with nothing to add to a calendar.
    [[ "$n" =~ ^[0-9]+$ ]] || { echo not_event; return; }
    (( n == 0 )) && { echo not_event; return; }
    echo events
}

# notify / retract / ntfy_muted / ntfy_id_safe moved to ntfy/ntfy.lib.sh (sourced
# at the top), unchanged. They existed here in four near-identical copies across the
# repo and had already drifted — two of the four had no --max-time, and one had no
# hdr_safe at all.
#
# What stays afterimage's own is which message gets which weight. Every proposal is
# published at the default: ranking them against each other was noise, because a
# past-event note is not more or less important than the event beside it. The
# priority argument is still passed, because the infrastructure alarms — a screenshot
# stuck in incoming/, a run that gave up — genuinely do want to shout.
#
# Tagging is also ours: an id is an ntfy sequence id, what retract() addresses and the
# only way to take a notification off the phone. Tag anything a later message will
# supersede; omit it for one-shot notices nothing will ever withdraw, where being
# unretractable is the correct behaviour.

# write_context <record-dir> <now-local> <image> <prompt>
# Everything needed to interpret this record later, written when the capture is
# claimed so it survives an API failure too.
#
# The prompt is stored in full, not just hashed. A record has to be readable on its
# own — without checking out the commit the repo happened to be on that day — and
# 2KB of text next to a 2MB screenshot costs nothing. The hash is there so records
# can be grouped by prompt version without diffing text. The schema is hashed only,
# since it is long and rarely the thing you are asking about.
#
# Without this, a proposal cannot be attributed: the prompt changed twice on
# 2026-07-27 alone, so a difference between two records could be the prompt, the
# model, or the screenshot, with no way to tell which.
write_context() {
    local rec="$1" now_local="$2" img="$3" prompt="$4" memory="${5:-}"
    local psha ssha bytes tmpl
    # Hash the TEMPLATE, not the rendered prompt. The prompt embeds the capture
    # time, so hashing the rendered text gave every capture a unique digest — seven
    # captures produced five hashes on 2026-07-27 — which defeats the only thing the
    # field is for: grouping records by prompt version. Substituting the timestamp
    # back out makes the digest stable across captures and change only when the
    # wording does.
    #
    # The MEMORY block comes out the same way and for the same reason: it is different
    # on every capture by design. It is kept in full beside the prompt, so a strange
    # proposal can be traced to the note that steered it.
    tmpl="$prompt"
    [[ -n "$memory" ]] && tmpl="${tmpl//"${memory}"/<MEMORY>}"
    psha="$(printf '%s' "${tmpl//${now_local}/<NOW>}" | sha256sum | cut -d' ' -f1)"
    ssha="$(printf '%s' "$CAPTURE_SCHEMA" | sha256sum | cut -d' ' -f1)"
    bytes="$(stat -c %s "$img" 2>/dev/null || echo 0)"

    jq -n --arg captured_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          --arg captured_at_local "$now_local" --arg event_tz "$EVENT_TZ" \
          --arg model "$AI_MODEL" --arg effort "$AI_EFFORT" \
          --arg prompt "$prompt" --arg prompt_sha256 "$psha" --arg memory "$memory" \
          --arg schema_sha256 "$ssha" --arg mime "$(image_mime "$img")" \
          --argjson bytes "$bytes" --argjson duration_min "$DURATION_MIN" \
        '{captured_at:$captured_at, captured_at_local:$captured_at_local,
          event_tz:$event_tz,
          model:$model, effort:$effort, duration_min:$duration_min,
          prompt_sha256:$prompt_sha256, schema_sha256:$schema_sha256,
          image:{mime:$mime, bytes:$bytes},
          memory:$memory, prompt:$prompt}' > "${rec}/context.json"
}

# add_usage <record-dir> <api-response>
# Fold the API's token counts into context.json once the call has returned. This is
# what answers "would a cheaper model do" without re-running anything.
#
# The model the RESPONSE names overwrites the one write_context recorded: if the
# newest model rejected the request, api_post retried on the last one that worked,
# and only the reply knows which of the two answered.
add_usage() {
    local rec="$1" resp="$2" tmp
    [[ -f "${rec}/context.json" ]] || return 0
    tmp="$(mktemp)"
    if jq --argjson usage "$(jq -c '.usage // {}' <<<"$resp" 2>/dev/null || echo '{}')" \
          --arg model "$(jq -r '.model // empty' <<<"$resp" 2>/dev/null)" \
          '. + {usage:$usage} + (if $model != "" then {model:$model} else {} end)' \
          "${rec}/context.json" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "${rec}/context.json"
    else
        rm -f "$tmp"
    fi
}

# archive_record <id> <src-dir> <outcome> [note]
# Resolve a capture: stamp the verdict into decision.json and move the whole
# record (screenshot + proposal + rendered .ics) into the archive. The record IS
# the history — there is no ledger beside it.
# Outcomes: add | add_alt | discard | ignored | needs_human | not_event | failed
archive_record() {
    local id="$1" src="$2" outcome="$3" note="${4:-}"
    local dest="${ARCHIVE_DIR}/${id}"
    [[ -d "$src" ]] || return 1

    mkdir -p "$ARCHIVE_DIR"

    local decided proposed latency anchor
    decided="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # proposal.json's mtime is when the model answered. The record DIRECTORY was
    # used here before, but a directory's mtime moves every time a file is written
    # into it — including the sweep's own renotified/requeued markers — so the two
    # halves of this pipeline were writing the same field under two different
    # definitions. server.ts stats proposal.json; match it, and fall back to the
    # directory only when there is no proposal (a capture that failed before one).
    anchor="${src}/proposal.json"
    [[ -f "$anchor" ]] || anchor="$src"
    proposed="$(date -u -r "$anchor" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$decided")"
    latency=$(( $(date +%s) - $(stat -c %Y "$anchor" 2>/dev/null || date +%s) ))

    jq -n --arg id "$id" --arg outcome "$outcome" --arg note "$note" \
          --arg decided "$decided" --arg proposed "$proposed" --argjson latency "$latency" \
        '{id:$id, outcome:$outcome, note:$note, proposed_at:$proposed,
          decided_at:$decided, latency_s:$latency}' > "${src}/decision.json"

    rm -rf "$dest"
    mv "$src" "$dest" || return 1
    # NOT retracted here. Archiving happens in three places — this function, the
    # triage's terminal branches, and the container's own archive() on a tap — and
    # only one of them is host bash. The sweep withdraws notifications for
    # everything in archive/ in a single pass instead, so "resolved implies
    # withdrawn" holds however the record got resolved, including a tap.
}

# The capture service's own tailnet URL — the Add/Discard buttons POST back here,
# so the phone/laptop tapping them must be able to reach it (tailnet: yes).
#
# Every component is asserted: an unset var would otherwise yield a syntactically
# valid but dead URL ("https://host.ts.net:") and the buttons would fail silently
# on tap. Caught in live testing 2026-07-25 — fail loudly instead.
capture_base_url() {
    _load_env || return 1
    local host="${TAILNET_DOMAIN:-}.${TAILNET_DNS_NAME:-}" port="${AFTERIMAGE_REVERSE_PROXY_PORT:-}"
    [[ -n "${TAILNET_DOMAIN:-}" && -n "${TAILNET_DNS_NAME:-}" ]] || {
        log "TAILNET_DOMAIN/TAILNET_DNS_NAME unset in .env"; return 1; }
    [[ -n "$port" ]] || { log "AFTERIMAGE_REVERSE_PROXY_PORT unset in .env"; return 1; }
    printf 'https://%s:%s' "$host" "$port"
}

# Structured-output schema. Sent as output_config.format.schema, so the model
# cannot return anything but this shape (no parsing of prose, no retries on
# malformed JSON). additionalProperties:false is required by the API.
read -r -d '' CAPTURE_SCHEMA <<'JSON' || true
{
  "type": "object",
  "additionalProperties": false,
  "properties": {
    "is_event":    {"type": "boolean"},
    "needs_human": {"type": "boolean"},
    "events_seen": {"type": "integer"},
    "reason":      {"type": ["string", "null"]},
    "memory":      {"type": ["string", "null"]},
    "events": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "properties": {
          "calendar":    {"type": "string", "enum": ["general", "birthday"]},
          "title":       {"type": "string"},
          "date":        {"type": "string"},
          "end_date":    {"type": ["string", "null"]},
          "start_time":  {"type": ["string", "null"]},
          "end_time":    {"type": ["string", "null"]},
          "all_day":     {"type": "boolean"},
          "timezone":    {"type": "string"},
          "recurrence":  {"type": "string", "enum": ["none","yearly","monthly","weekly","daily"]},
          "location":    {"type": ["string", "null"]},
          "conference":  {"type": ["string", "null"]},
          "description": {"type": ["string", "null"]},
          "alternatives": {
            "type": "array",
            "items": {
              "type": "object",
              "additionalProperties": false,
              "properties": {
                "date":       {"type": "string"},
                "start_time": {"type": ["string", "null"]},
                "end_time":   {"type": ["string", "null"]},
                "location":   {"type": ["string", "null"]}
              },
              "required": ["date", "start_time", "end_time", "location"]
            }
          }
        },
        "required": ["calendar","title","date","end_date","start_time","end_time","all_day",
                     "timezone","recurrence","location","conference","description","alternatives"]
      }
    }
  },
  "required": ["is_event","needs_human","events_seen","reason","memory","events"]
}
JSON
