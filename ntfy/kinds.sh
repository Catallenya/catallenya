#!/usr/bin/env bash
# shellcheck disable=SC2034  # the vocabulary arrays are consumed by systemd/contract.sh
# Title constructors. Sourced, never executed.
#
# SOURCED BY ntfy/ntfy.lib.sh, not by consumers directly. Eight scripts already source
# the transport; making each of them source a second file would be eight chances to
# forget one, and the one that forgot would fail at runtime with "title_count: command
# not found" inside a failure handler. A caller that can notify can always build a
# title. Nothing here depends on the transport, so the order between them is free.
#
# THE CONTRACT IS ntfy/MESSAGES.md. This file is the mechanism; that document is the
# source, and it is written to one test — everything is lost, someone has that one
# file, can they rebuild this system correctly. Elaborate here; never contradict there.
#
# WHY CONSTRUCTORS RATHER THAN A STYLE GUIDE. 32 emission points across 12 files grew
# SIX incompatible title grammars in about a year — `Staged: 3 Documents`,
# `Liquidroom: stems ready`, `Afterimage Gave Up`, `Immich rotation bake failed`,
# `Disk Space Alert`, `Backup Failure` — and every one of them was written by someone
# following whatever file they happened to have open. A rule you have to remember is a
# rule that is already false somewhere: `no high priority` was written down in two
# documents and was FALSE for nine days, in a wrapped call that the eye missed and the
# regex missed too.
#
# THE GATE IS THE LAYERING, and that is the one way this differs from the thing it is
# modelled on. systemd/policy/ works because systemd has a real merge engine — verified
# on this box, a unit's RuntimeMaxSec=999 lost to a drop-in's 111 — so its layering
# holds even when install.sh is wrong. There is no merge engine here. Nothing at
# runtime stops a caller passing notify() a hand-built string. `systemd/contract.sh`
# refusing that at --check time is the ONLY thing making these functions
# authoritative, which makes that rule load-bearing rather than tidiness.
#
# SANITATION IS DELIBERATELY ABSENT. notify() already runs hdr_safe on its first
# argument, so a name arriving here — a hand-typed track filename, a model-written
# event title — is handled at the same boundary as every other title. Re-applying it
# would put the CR/LF strip in two places, which is how the two copies drift.

# --- vocabulary --------------------------------------------------------------
# The MODEL class, and the only vocabulary that lives centrally. Both intake
# pipelines call ask() in ai/scripts/ai.lib.sh and have byte-identical branch
# structure around it, so an error from that layer is ONE fact arriving on several
# topics and must read identically on all of them. This is the generalisation of
# paused_title(), which encoded the same argument for one of the three outcomes and
# was never extended to the other two.
#
# `Model ` is a namespace prefix — the same move as `Still ` for nudges. It keeps the
# shared meaning unambiguous while leaving `Failed` free for the state slot elsewhere
# (`Backup: Failed`, `Rotation Bake: Failed`).
#
# `Abandoned` is deliberately NOT here and deliberately NOT prefixed: the 7-day
# give-up is this repo's own timer deciding to stop retrying. The cause is
# model-class, the decision is the pipeline's, and the missing prefix is what makes
# that difference visible on a lock screen.
NTFY_MODEL_VERBS=("Model Failed" "Model Paused")

# Every verb in a feature's NTFY_VERBS must be a past participle, and 22 of the 23
# verbs in the repo end in "ed" — so the gate can check the rule rather than trust it.
# This list is the escape hatch for the one that does not, and it should grow roughly
# never. The friction is the point: `Stray` and `Unclear` were both proposed during
# design and both are adjectives, and a looser check (reject "-ing" only) would have
# waved both through.
NTFY_IRREGULAR_VERBS=(Stuck)

# THE ONLY WORDS A RECEIPT MAY CARRY (owner, 2026-10-31). Quiet on success is the
# rule: a notification is a failure, a decision waiting for you, the result of
# something you asked for (including a failure that has since recovered), or a change
# in how your requests will be handled — never "all fine". A receipt is the only kind
# that can say good news, so its word is what the gate checks: systemd/contract.sh
# refuses a notify_receipt whose verb (title_count) or state (title_state) is not here.
#
# CENTRAL ON PURPOSE, unlike NTFY_VERBS. Each entry is an owner's decision that this
# piece of good news earns a buzz, and the friction of adding one here is the point —
# a new feature cannot drift loud without someone writing its word into this line.
#   Skipped Passed   afterimage: your screenshot was read, nothing to propose
#   Baked            immich: the rotation you made in the UI is now in the file
#   Downloaded Finished Skipped   liquidroom: your request, halfway and done
#   Cancelled        calendar feeds: an event you marked went away at its source
#   Archived         grayjay: a video you were told had failed is now saved
#   Changed          the model behind your proposals changed (`Model: Changed`)
NTFY_RECEIPT_VERBS=(Skipped Passed Baked Downloaded Finished Cancelled Archived Changed)

# --- geometry ----------------------------------------------------------------
# A phone lock screen truncates somewhere around here. The cap exists so WE choose
# what survives rather than the client: the verb is the word that makes a title
# scannable, so it is never the part that goes.
TITLE_MAX="${TITLE_MAX:-40}"
# Floor, so a long verb plus a bracket cannot squeeze a name to nothing. Reaching
# this means the title overruns TITLE_MAX, which is the better failure.
TITLE_MIN_NAME="${TITLE_MIN_NAME:-12}"

# _title_trunc <text> <max> — cap at <max> characters INCLUDING the ellipsis.
# One codepoint, not three dots: it is narrower on screen and buys two more
# characters of the name, which is the only part worth spending them on.
_title_trunc() {
    local s="${1:-}" max="${2:-0}"
    (( max < 1 )) && max=1
    (( ${#s} <= max )) && { printf '%s' "$s"; return 0; }
    printf '%s…' "${s:0:$(( max - 1 ))}"
}

# --- brackets ----------------------------------------------------------------
# Every qualifier a title can carry rides in square brackets, built here so the
# delimiter is decided once: position [2/4], age [1d], model-pause cause [Unpaid],
# and the courier's rerouted topic [restic].

# title_mark <text> -> "[text]", or nothing for an empty argument.
title_mark() { [[ -n "${1:-}" ]] && printf '[%s]' "$1"; return 0; }

# title_pos <n> <of> -> "[2/4]", or nothing when there is only one of the thing.
# Silent at of<=1 so a caller can pass its position unconditionally.
title_pos() {
    local n="${1:-0}" of="${2:-0}"
    (( of > 1 )) || return 0
    title_mark "${n}/${of}"
}

# title_age <hours> -> "[6h]" | "[1d]" | "[3w]"
#
# Coarse on purpose. Both pipelines nudge exactly ONCE — guarded by a `renotified`
# marker — and the nightly sweep means the value can only land between 24h and 48h,
# so a precise number would report sweep timing rather than urgency. The scale runs
# past that anyway, because a marker that only ever prints one of two values invites
# someone to hardcode it.
title_age() {
    local h="${1:-0}"
    if   (( h <  24 )); then title_mark "${h}h"
    elif (( h < 336 )); then title_mark "$(( h / 24 ))d"
    else                     title_mark "$(( h / 168 ))w"
    fi
}

# --- titles ------------------------------------------------------------------

# title_count <Verb> <n> <Noun> [name] [mark] -> a REPORT: what happened, to how many
#
#   title_count Staged 3 Document                    -> "Staged: 3 Documents"
#   title_count Blocked 1 Document                   -> "Blocked: 1 Document"
#   title_count "Still Staged" 3 Document "" "[1d]"  -> "Still Staged: 3 Documents [1d]"
#   title_count Flagged 1 Event "Kene"               -> "Flagged: Kene"
#
# THE VERB IS A PAST PARTICIPLE, ALWAYS. The title reports what happened; the button
# carries the imperative. That is why `Review:` became `Flagged:` — it was the one
# title telling you what to do while sitting above two buttons already saying so.
#
# THE DIGIT SURVIVES AT ONE. "Blocked: 1 Document", never "Blocked: Document": the
# count then sits in the same position in every title and can be read without parsing
# the sentence.
#
# A NAME REPLACES THE COUNT when the caller passes one, because for a single item the
# name is the more useful fact — "Still Waiting: 1 Event" is a nudge that does not say
# which event. Callers that have names and deliberately keep them in the BODY, as
# pigeonhole does with filenames, simply pass none.
title_count() {
    local verb="${1:?title_count: verb}" n="${2:?title_count: count}"
    local noun="${3:?title_count: noun}" name="${4:-}" mark="${5:-}"
    local head="${verb}: " tail="" body budget

    [[ -n "$mark" ]] && tail=" ${mark}"

    if [[ -n "$name" ]]; then
        budget=$(( TITLE_MAX - ${#head} - ${#tail} ))
        (( budget < TITLE_MIN_NAME )) && budget=$TITLE_MIN_NAME
        body="$(_title_trunc "$name" "$budget")"
    else
        # Never truncated: a count body is short by construction, and cutting it
        # would remove the number this shape exists to show.
        body="${n} ${noun}$( (( n == 1 )) || printf s )"
    fi
    printf '%s%s%s' "$head" "$body" "$tail"
}

# title_state <Subject> <State> [mark] -> a FAULT or a RECEIPT: what is, with what
#
#   title_state zpool "78% Full"           -> "zpool: 78% Full"
#   title_state Watchdog "3 Findings"      -> "Watchdog: 3 Findings"
#   title_state Backup Succeeded           -> "Backup: Succeeded"
#
# THE SUBJECT MUST BE NARROWER THAN THE TOPIC. A title never repeats what the topic
# already said, so on topic `disk` the subject is `zpool` or `root` — which is not
# pedantry, it is the reason this shape carries more than the literal it replaced:
# `Disk Space Alert` never said which filesystem, or how full.
#
# IDENTIFIERS KEEP THEIR REAL CASE. The pool is literally called `zpool`; printing
# `Zpool` would name something that does not exist. Ordinary words take Title Case.
#
# THE STATE CARRIES A NUMBER WHERE ONE NATURALLY FITS, and a bare participle or phrase
# where one does not — `Backup: Succeeded`, `Rotation Bake: Failed`. Strong preference
# for the number; forcing it produced `Backup: 1 Success`, counting a thing that is
# always exactly one.
#
# THE SUBJECT IS CAPPED, the state is not. Almost every subject here is ours and short
# — `zpool`, `Boot`, `Rotation Bake` — and the cap never fires for those. The one that
# is not ours is changedetection naming a single broken watch, whose title comes from
# that container's API and is whatever the owner typed into a web form. The state
# stays whole because it is the half that carries the fact.
title_state() {
    local subject="${1:?title_state: subject}" state="${2:?title_state: state}"
    local mark="${3:-}" tail=""
    [[ -n "$mark" ]] && tail=" ${mark}"
    subject="$(_title_trunc "$subject" "$(( TITLE_MAX - ${#state} - ${#tail} - 2 ))")"
    printf '%s: %s%s' "$subject" "$state" "$tail"
}

# title_quote <name> [mark] -> a QUOTATION: the world's own words
#
#   title_quote "Kene"                      -> "Kene"
#   title_quote "Kene" "$(title_pos 2 4)"   -> "Kene [2/4]"
#   title_quote "Kene" "$(title_age 31)"    -> "Kene [1d]"
#
# The only titles with no verb, and deliberately so: an afterimage proposal's title IS
# the event's name, lifted off a screenshot, and "Kene" says more at a glance than any
# verb this repo could put in front of it.
#
# THIS IS ALSO WHY A PROPOSAL'S NUDGE HAS NO VERB. Every other nudge is `Still ` plus
# the original verb, but a quotation has no verb to reuse, so the age bracket alone
# marks it. afterimage therefore has two nudge shapes on purpose: quotations nudge as
# quotations.
title_quote() {
    local name="${1:-Untitled}" mark="${2:-}" tail=""
    [[ -n "$mark" ]] && tail=" ${mark}"
    printf '%s%s' "$(_title_trunc "$name" "$(( TITLE_MAX - ${#tail} ))")" "$tail"
}

# --- kinds -------------------------------------------------------------------
# WHAT A KIND IS. Every notification this box sends is one of five things, and which
# one decides what arguments exist. That is the whole mechanism: a receipt has no
# parameter to put a button in, so it cannot grow one; a proposal cannot omit the
# sequence-id that makes it withdrawable, because the id is required.
#
# THEY PRODUCE NO VISIBLE DIFFERENCE, and it is worth being honest about that. Tags
# were dropped in the same change, so every message renders as title plus body
# regardless of kind. The value is structural — the rules above become impossible to
# break rather than merely forbidden — and it is what lets systemd/contract.sh refuse
# a bare notify() from outside this directory.
#
# THE WITHDRAWAL RULE (owner, 2026-08-20), which is why the signatures differ:
#
#   A notification WITH buttons may be withdrawn. A notification WITHOUT buttons is
#   never withdrawn by the system.
#
# An actionable message is withdrawn by the tap that resolves it, or by afterimage's
# archive backstop once its buttons have started answering 404 — a control that lies
# is worse than no control. Everything else stays until you swipe it, because an
# absent notification is ambiguous and a stale one is not. See ntfy/MESSAGES.md.

# notify_proposal <title> <body> <actions> <seq-id>
# Something is waiting for a tap, first time of asking. Both trailing arguments are
# REQUIRED: buttons with no id would be a decision nothing could ever withdraw.
notify_proposal() {
    notify "${1:?notify_proposal: title}" "${2:?notify_proposal: body}" \
           "${3:?notify_proposal: actions}" "${4:?notify_proposal: sequence-id}"
}

# notify_nudge <title> <body> <seq-id> [actions]
# The same decision, asked again. RETRACTS FIRST so the phone ends up with one
# message rather than two — which is why the id comes before the optional actions.
#
# Retract-then-publish rather than an in-place update: an update may be applied
# silently, and a nudge that does not alert is not a nudge. Seven call sites used to
# write the retract by hand immediately above their notify; doing it here is one
# fewer thing to forget.
#
# Actions are optional because afterimage's needs-a-human nudge has none — it carries
# an id so the sweep can replace it, but there is nothing to tap.
notify_nudge() {
    local id="${3:?notify_nudge: sequence-id}"
    retract "$id"
    notify "${1:?notify_nudge: title}" "${2:?notify_nudge: body}" "${4:-}" "$id"
}

# notify_resolved <title> <body> <seq-id> [actions]
# Resolved without you — binned at seven days, given up on. Mechanically identical to
# a nudge and kept separate because the call site should say which it is, and because
# the gate holds a nudge to a `Still ` title while this is free of that.
notify_resolved() {
    local id="${3:?notify_resolved: sequence-id}"
    retract "$id"
    notify "${1:?notify_resolved: title}" "${2:?notify_resolved: body}" "${4:-}" "$id"
}

# notify_fault <title> <body> [seq-id]
# Something broke. Never has buttons, so it is never withdrawn — see the rule above.
#
# THE ID IS OPTIONAL AND MEANS "this condition can recur". A job that runs on a
# schedule and can report the same finding twice passes a stable literal, so the
# second run REPLACES the first instead of stacking beside it: host/disk.sh runs
# hourly, and a pool sitting over threshold across a weekend used to produce
# forty-five notifications. A one-shot fault about a single item — Model Failed,
# Abandoned, Refused — passes none, because nothing later will ever replace it.
#
# MUST STAY OUTPUT-TRANSPARENT. disk.sh, catallenya.sh, heartbeat.sh and
# changedetection.health.sh capture this call's output and treat ANY output as an
# undelivered alert, because for them the notification is the work. Nothing may be
# printed on the success path.
notify_fault() {
    notify "${1:?notify_fault: title}" "${2:?notify_fault: body}" "" "${3:-}"
}

# notify_receipt <title> <body>
# Work finished, nothing owed. No buttons and no id, both by construction: there is
# no argument to put them in, so a receipt can never become something you must act on
# and can never be withdrawn.
notify_receipt() {
    notify "${1:?notify_receipt: title}" "${2:?notify_receipt: body}"
}

# --- bodies ------------------------------------------------------------------
# WHY THESE EXIST. Bodies were hand-assembled strings, which is the only reason
# NTFY_MARKDOWN existed because five publishers turned rendering OFF: their bodies
# carry raw filenames, and a camera name like photo_2026_08_01.jpg comes out with its
# middle italicised — or worse, a filename arriving over Syncthing could hide a live
# `[tap here](https://evil)` inside a notification you already trust. Escaping in one
# place is what makes rendering safe everywhere, so the flag went (2026-08-21).
#
# The DEVICE QUIRKS below were learned on the actual phone, and they were being
# copy-pasted: pigeonhole discovered them, then liquidroom copied the `1\.` trick with
# a comment citing pigeonhole as the precedent. That is the same drift signature that
# produced four copies of notify(). One renderer means one place to fix them.

# The item indent. NBSP+space pairs, NOT four ordinary spaces: the ntfy web renderer
# collapses ordinary leading whitespace, so a plain-space indent vanishes there while
# looking correct on Android. Copied byte-for-byte from pigeonhole's batch_list, where
# it was arrived at empirically alongside hard breaks, an ASCII tree, a fenced block
# and inline code spans — all tried the same day and rejected on the device.
BODY_INDENT=$'        '

# How many items before summarising. Five is what the paused summary already used, so
# it is a shape the owner has read before. The cap also matters for a reason nothing
# in the body can see: ntfy silently converts a body over 4096 bytes into an
# ATTACHMENT, whose content expires in three hours.
BODY_LIST_MAX="${BODY_LIST_MAX:-5}"

# body_list [--all] <item>... -> the numbered list every body is built from.
#
# An item may carry a DETAIL after a TAB, rendered indented beneath its name:
#
#   body_list "IMG_1234.jpg"$'\t'"rotated 90°"
#
#       1\. IMG_1234.jpg
#           rotated 90°
#
# `1\.` is ESCAPED and therefore not a real ordered list. It has to be: the Android
# app renders genuine markdown list markers as unnumbered dots, so the numbers — the
# thing that lets you check a list against the count in the title — silently vanish.
#
# The trailing two spaces are a markdown HARD BREAK, without which the detail line
# joins the name line into one paragraph.
#
# --all disables the cap, for the one list that must show every member: pigeonhole's
# staged batch, whose Accept files ALL of them. Showing 5 of 12 above a button that
# acts on 12 means approving seven documents you never saw.
body_list() {
    local all=0
    [[ "${1:-}" == "--all" ]] && { all=1; shift; }
    local -a items=("$@")
    local n=${#items[@]} shown i out="" name detail
    shown=$n
    (( all )) || (( shown <= BODY_LIST_MAX )) || shown=$BODY_LIST_MAX
    for (( i = 0; i < shown; i++ )); do
        name="${items[$i]%%$'\t'*}"
        detail=""
        [[ "${items[$i]}" == *$'\t'* ]] && detail="${items[$i]#*$'\t'}"
        out+="$(( i + 1 ))\\. $(md_escape "$name")"
        [[ -n "$detail" ]] && out+="  "$'\n'"${BODY_INDENT}$(md_escape "$detail")"
        out+=$'\n'
    done
    # ITALIC, because this is a truncation count and that is the one thing italics
    # mean here. body_aside is the renderer for all three forms; using it rather than
    # a literal is what stops this line drifting away from the other two.
    (( n > shown )) && out+="$(body_aside "… and $(( n - shown )) more")"$'\n'
    printf '%s' "$out"
}

# The fact marker. U+2022 BULLET, chosen 2026-08-22 over U+25AA BLACK SMALL SQUARE,
# which shipped first and had one defect that mattered: it has an EMOJI PRESENTATION,
# so some Android builds draw it as a COLOURED SQUARE. A marker that renders as an
# emoji on the device it is read on is not a marker.
#
# Also rejected: `-`, `*` and `+`, which markdown turns into a real list — the same
# trap the escaped `1\.` exists for — and which would then need escaping to survive.
# `-` fails a second way, on the body it appears in most: `- 19:30 - 21:00` puts
# three hyphens on one line meaning two different things.
#
# The bullet needs NO escape (it has no markdown meaning) and is not emoji-capable,
# which is the whole of why it wins. It DID collide with one thing — afterimage used
# " • " as its "or" separator between alternative times — so that moved to " / " on
# the same day. See ALT_SEP in afterimage/scripts/afterimage.lib.sh.
BODY_FACT_MARK=$'\u2022'

# body_fact <line>... -> the • metric lines, one per argument.
#
#   body_fact "1.3T of 1.7T used" "400G free"
#
#       • 1.3T of 1.7T used
#       • 400G free
#
# A FACT IS SELF-DESCRIBING AND CARRIES NO STUB LABEL. `• Free: 400G` names a
# category; `• 400G free` states something. The distinction is not decoration — a
# detail hangs off the item above it, so a label says WHICH ASPECT of that item,
# while a fact stands alone and therefore has to describe itself.
#
# The failure mode this invites is dropping context to keep the line short:
# `• about 70m` is terse and means nothing. Where prose reads badly, the answer is a
# FULL DESCRIPTIVE PHRASE — `• Estimated time left: 70m` — never a stub. A fact must
# read as a complete statement; how many words that takes is not the constraint.
#
# No full stop, on any body line (settled 2026-08-21). A stop after a path reads as
# part of the filename, and one rule beats remembering which line type you are on.
#
# No hard break between lines: the ntfy renderer breaks on a single newline, which is
# why body_list's items need none either. (The hard break body_list puts above a
# DETAIL is belt-and-braces from the day the indent was worked out; harmless, kept.)
body_fact() {
    local out="" line
    for line in "$@"; do
        [[ -n "$line" ]] || continue
        out+="${BODY_FACT_MARK} $(md_escape "$line")"$'\n'
    done
    printf '%s' "$out"
}

# body_join <section>... -> the body, with the blank lines between sections.
#
#   body_join "$(body_list "${ITEMS[@]}")" "$(body_fact "${FACTS[@]}")" "$prose"
#
# THE ORDER RULE IS ITEMS, BLANK, FACTS, BLANK, PROSE, and it exists because a body
# read on a lock screen is scanned rather than read: what happened, then the numbers,
# then the explanation. Callers used to write that blank line themselves, inside a
# quoted string, which is the kind of thing that is right the first time and wrong the
# third — `$( )` strips trailing newlines, so a section boundary needs TWO literal
# newlines and looks like a typo with one.
#
# An EMPTY section is dropped rather than joined, so a body with no items does not
# open with a blank line and a body with no prose does not end with one.
#
# IT ESCAPES NOTHING, and must not: its arguments are already-rendered sections whose
# own renderer escaped them, and escaping twice turns `1\.` into `1\\.`. The one
# argument that is not pre-rendered is the PROSE, which is therefore the caller's to
# escape — trivially true when the sentence is ours, and mandatory when any part of it
# came from a model or a filename. Prose is also the only place markdown syntax can
# reach a body by accident: `Only *.png is triaged` puts a live emphasis marker in an
# otherwise literal sentence, so write around it rather than relying on it not pairing.
body_join() {
    local out="" section
    for section in "$@"; do
        [[ -n "${section//[[:space:]]/}" ]] || continue
        [[ -z "$out" ]] || out+=$'\n\n'
        out+="${section%$'\n'}"
    done
    printf '%s' "$out"
}

# body_aside <text> -> the italic truncation count.
#
# ITALIC MEANS "THIS IS NOT THE WHOLE STORY", and nothing else. It marks the three
# forms of truncation and no other text: `… and 3 more` (the list was cut at five),
# `3 more still queued` (work is waiting for the next run), `3 more events not sent`
# (data was dropped and is gone). An ETA or a parked reason is a FACT — use body_fact.
# The scope was narrowed on 2026-08-21: italics that mean several things mean nothing.
#
# Escaped like everything else, then wrapped: the underscores that make it italic are
# added AFTER md_escape, so a name inside the text cannot break out of the emphasis.
body_aside() {
    [[ -n "${1:-}" ]] || return 0
    printf '_%s_' "$(md_escape "$1")"
}
