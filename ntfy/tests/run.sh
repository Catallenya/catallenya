#!/usr/bin/env bash
# Regression tests for the shared ntfy transport (ntfy/ntfy.lib.sh).
#
# Everything here runs offline and sends nothing: the suite exports NTFY_DISABLE=1,
# and every case below exercises string construction rather than the wire.
#
# This file exists because the transport stopped being four private copies and became
# one shared thing on 2026-08-10. The sanitisers in particular had never had a direct
# test in any of their homes — the pipeline suites only ever grepped the source to
# check they were still being CALLED. Both guard real attacks, so they are tested on
# behaviour here. Run before commit:
#   bash ntfy/tests/run.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export NTFY_DISABLE=1
# shellcheck source=../ntfy.lib.sh
source "${SELF_DIR}/../ntfy.lib.sh"
# shellcheck source=../../ai/scripts/ai.lib.sh
source "/zpool/catallenya/ai/scripts/ai.lib.sh"

PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
is()   { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "$3" "$2"; }
has()  { [[ "$2" == *"$3"* ]] && ok "$1" || bad "$1" "contains $3" "$2"; }
hasnt(){ [[ "$2" != *"$3"* ]] && ok "$1" || bad "$1" "must not contain $3" "$2"; }

# ------------------------------------------------------------------ sanitisers
# hdr_safe guards an HTTP header. A CR/LF in a title injects a SECOND Actions
# header, and Go's Header.Get returns the FIRST — so the injected buttons REPLACE
# the real ones and a tap POSTs wherever the attacker chose. Titles are untrusted on
# every pipeline: a screenshot can show anything, a filename arrives over Syncthing.
echo "hdr_safe"
is "strips CR"                  "$(hdr_safe $'a\rb')" "ab"
is "strips LF"                  "$(hdr_safe $'a\nb')" "ab"
is "kills a header injection"   "$(hdr_safe $'Title\r\nActions: http, Add, https://evil/')" \
                                "TitleActions: http, Add, https://evil/"
hasnt "no newline survives"     "$(hdr_safe $'x\r\ny')" $'\n'
long="$(hdr_safe "$(printf 'a%.0s' {1..500})")"
is "caps length at 200"         "${#long}" "200"
is "empty input is empty"       "$(hdr_safe "")" ""
is "missing arg is empty"       "$(hdr_safe)" ""

# md_escape guards a RENDERED body. Bodies go out with Markdown on, so a
# [tap here](https://evil.example) lifted from a document or a screenshot would
# become a real link inside a notification the owner already trusts.
echo "md_escape"
is "escapes a link"      "$(md_escape '[tap](https://evil)')" '\[tap\]\(https://evil\)'
is "escapes underscores" "$(md_escape 'photo_2026_08.jpg')"   'photo\_2026\_08.jpg'
is "escapes asterisks"   "$(md_escape '*bold*')"              '\*bold\*'
is "backslash first"     "$(md_escape '\*')"                  '\\\*'
is "leaves plain text"   "$(md_escape 'tax-invoice.pdf')"     'tax-invoice.pdf'
is "empty is empty"      "$(md_escape "")"                    ""

# ntfy_id_safe: the id reaches ntfy as BOTH a header value and a URL path segment.
echo "ntfy_id_safe"
is "keeps a uuid"        "$(ntfy_id_safe '8f3a91c2-0000-4aaa-bbbb-ccccdddd')" '8f3a91c2-0000-4aaa-bbbb-ccccdddd'
is "drops a slash"       "$(ntfy_id_safe 'a/b')"   'ab'
is "bare traversal empties" "$(ntfy_id_safe '..')" ''
is "leading dots go"     "$(ntfy_id_safe '..x')"   'x'

# ------------------------------------------------------------------- the shape
echo "paused_title"
is "plural by default"   "$(paused_title 3 Document)"   "Model Paused: 3 Documents"
is "singular at one"     "$(paused_title 1 Document)"   "Model Paused: 1 Document"
is "zero is plural"      "$(paused_title 0 Document)"   "Model Paused: 0 Documents"
is "noun is the caller's" "$(paused_title 2 Screenshot)" "Model Paused: 2 Screenshots"

echo "paused_body"
b="$(paused_body "Out of credits" "Moved to bin/ in 7 days." one two three)"
has "numbers the items"      "$b" '1\. one'
has "and keeps going"        "$b" '3\. three'
hasnt "no summary under cap" "$b" "more"
# ITEMS, then FACTS, then PROSE. It used to be one italic line reading
# "_Out of credits. Retrying daily — moved to bin/ in 7 days._": three separate facts
# run together, whispered, and joined by an em-dash. Italics mean truncation here and
# nothing else, so nothing in this body is italic any more.
has "the reason is a fact"   "$b" $'\u2022 Out of credits'
has "so is the cadence"      "$b" $'\u2022 Retrying daily'
has "the outcome is prose"   "$b" "Moved to bin/ in 7 days."
hasnt "and nothing whispers" "$b" "_Out of credits"
# REGRESSION: `local n=... shown="$n"` reads the OUTER n, because bash expands every
# right-hand side in one `local` before assigning any of them. That shipped for
# exactly one run of this file and printed the summary line with no items at all.
has "items actually render"  "$b" '2\. two'

b8="$(paused_body "Out of credits" "Binned in 7 days." a b c d e f g h)"
has "caps the list at five"  "$b8" '5\. e'
hasnt "and stops there"      "$b8" '6\.'
has "counts what it omitted" "$b8" "… and 3 more"

bx="$(paused_body "Out of credits" "Binned in 7 days." 'lab_report.pdf' '[tap](https://evil)')"
has "escapes an item"        "$bx" 'lab\_report.pdf'
has "an item cannot inject a link" "$bx" '\[tap\]\(https://evil\)'

# ------------------------------------------------- one outage, one wording
# The point of the shared shape: the same failure must read identically wherever it
# lands. Only the noun and the day-7 clause may differ, and the reason line comes
# from ai_reason() so no consumer can author its own.
echo "identical across pipelines"
r="$(ai_reason 3)"
pig="$(paused_body "$r" "Moved to bin/ in 7 days. Nothing is deleted." a)"
aft="$(paused_body "$r" "Archived in 7 days, and the screenshots go with them." a)"
is "same reason clause" \
   "$(grep -o $'\u2022 Out of credits' <<<"$pig")" \
   "$(grep -o $'\u2022 Out of credits' <<<"$aft")"
is "reason is not the caller's to write" "$r" "Out of credits"
is "a timeout reads differently"         "$(ai_reason 2)" "The API is unreachable"

# ------------------------------------------------- paused_sync choreography
# paused_sync is proven by SHADOWING notify/retract inside a subshell: the shadows
# print the argv they receive, so the assertions read the exact choreography — what
# was retracted, what was published, in what order — with no wire involved. The
# real functions stay muted underneath (NTFY_DISABLE=1) in case a shadow is missed.
echo "paused_sync"
sync_trace() {
    (
        retract() { printf 'RETRACT %s\n' "${1:-}"; }
        # notify <title> <body> [actions] [seq-id] — priority and tags were removed
        # from the signature on 2026-08-20.
        notify()  { printf 'NOTIFY title=[%s] actions=[%s] id=[%s]\n%s\n' \
                        "${1:-}" "${3:-}" "${4:-}" "${2:-}"; }
        paused_sync "$@"
    )
}

# The CAUSE is the fourth argument, between the reason and the outcome clause: it
# becomes the bracket on the title, while the reason stays in the body sentence.
t="$(sync_trace pause-1 Document "Out of credits" Unpaid "Moved to bin/ in 7 days." a.pdf b.pdf)"
is  "retract fires first, before any publish" "$(head -n1 <<<"$t")" "RETRACT pause-1"
has "then the summary, count and noun threaded" "$t" "title=[Model Paused: 2 Documents [Unpaid]]"
has "no buttons on a summary"            "$t" "actions=[]"
has "replacement rides the SAME id"      "$t" "id=[pause-1]"
has "items reach paused_body"            "$t" '1\. a.pdf'
has "reason reaches the body, in its own arg order" "$t" $'\u2022 Out of credits'
has "and so does the outcome"            "$t" "Moved to bin/ in 7 days."

# THE RUN THAT ENDS AN OUTAGE DOES NOTHING, and that is a DELIBERATE REVERSAL of the
# 2026-08-19 behaviour rather than a regression — see paused_sync's own comment.
#
# That change made the retract unconditional so a resolved outage cleared the summary.
# The withdrawal rule (2026-08-20) says the opposite: a notification WITHOUT BUTTONS is
# never withdrawn by the system, because an absent notification is ambiguous — fixed,
# mis-swiped, or never sent — while a stale one is not. The summary still replaces
# itself WHILE an outage runs, which is what the retract above proves; it simply stops
# updating once nothing is paused, and the last one waits to be swiped.
t0="$(sync_trace pause-1 Document "" "")"
is "resolved outage: nothing retracted, nothing published" "$t0" ""
is "a bare id publishes nothing either"                    "$(sync_trace pause-1)" ""

# An empty id would publish a summary nothing can ever withdraw; the call declines.
te="$(sync_trace "" Document "Out of credits" "x" a.pdf 2>/dev/null)"
is "no id: nothing retracted, nothing published" "$te" ""

# ------------------------------------------------------------------- _ntfy_env
# The extractor is shared and the KEY LISTS are not: afterimage and pigeonhole each
# wrap this with the one extra key their own callbacks need. What is pinned here is
# that the wrapping is possible at all — an extra key is read, and an extra key that
# is missing is the caller's problem rather than a failed transport.
#
# It reads the real /zpool/catallenya/.env, which is the file production reads and
# the same one every notify() in the other suites already goes through. Nothing is
# asserted about its CONTENTS beyond the three keys the transport itself requires.
echo "_ntfy_env"
env_probe() { ( unset SYNCTHING_REVERSE_PROXY_PORT; _ntfy_env "$@" >/dev/null 2>&1 \
                && printf '%s' "${SYNCTHING_REVERSE_PROXY_PORT:-unset}" ); }
is "an extra key is extracted" "$(env_probe SYNCTHING_REVERSE_PROXY_PORT)" \
   "$(grep -m1 '^SYNCTHING_REVERSE_PROXY_PORT=' /zpool/catallenya/.env | cut -d= -f2-)"
is "and is not read unless asked for"   "$(env_probe)"                    "unset"
is "an absent extra key is not fatal"   "$(_ntfy_env NO_SUCH_KEY_IN_ENV; echo rc=$?)" "rc=0"
# The trio IS asserted, because notify() builds a URL out of it and an unset
# component yields a syntactically valid but dead "https://host.ts.net:".
fn="$(sed -n '/^_ntfy_env() {/,/^}/p' "${SELF_DIR}/../ntfy.lib.sh")"
has "the caller's keys ride after the trio" "$fn" 'NTFY_REVERSE_PROXY_PORT "$@"'
has "and the trio is still required"        "$fn" 'NTFY_REVERSE_PROXY_PORT:-'
# Both wrappers are one line naming one key. A union list here would be a contract
# nobody wrote, and the next pipeline would silently inherit it.
for w in /zpool/catallenya/afterimage/scripts/afterimage.lib.sh \
         /zpool/catallenya/pigeonhole/scripts/pigeonhole.lib.sh; do
    is "$(basename "$w" .lib.sh) wraps it with its own key" \
       "$(grep -c '^_load_env() { _ntfy_env [A-Z_]* *; *}$' "$w")" "1"
done

# ------------------------------------------------------------------ mute seam
echo "mute seam"
is "the suite is muted"  "$(ntfy_muted && echo yes)" "yes"
# shellcheck disable=SC2034  # read by notify()/retract() in the sourced lib
NTFY_TOPIC=test-topic
is "notify is a no-op when muted"  "$(notify "t" "" tag "body"; echo rc=$?)" "rc=0"
is "retract is a no-op when muted" "$(retract deadbeef; echo rc=$?)"          "rc=0"
is "retract declines an empty id"  "$(retract ""; echo rc=$?)"                "rc=0"

# ------------------------------------------------------------------ constructors
# The SNAPSHOT. There is no `systemctl cat` for a message — nothing can say what a
# title will look like without running the code — so this is the merged view: one
# rendering per shape, asserted byte-for-byte. If a constructor changes, this is what
# tells you which titles moved.
echo "title constructors"
is "count, plural"        "$(title_count Staged 3 Document)"        "Staged: 3 Documents"
is "count, singular"      "$(title_count Blocked 1 Document)"       "Blocked: 1 Document"
is "the digit survives"   "$(title_count Binned 1 Document)"        "Binned: 1 Document"
is "a multi-word verb"    "$(title_count "Model Failed" 1 Screenshot)" "Model Failed: 1 Screenshot"
is "a name replaces the count" "$(title_count Flagged 1 Event Kene)" "Flagged: Kene"
is "a nudge carries its age"   "$(title_count "Still Staged" 3 Document "" "$(title_age 31)")" \
                               "Still Staged: 3 Documents [1d]"
is "state, counted"       "$(title_state Watchdog "3 Findings")"    "Watchdog: 3 Findings"
is "state, bare"          "$(title_state Backup Succeeded)"         "Backup: Succeeded"
is "an identifier keeps its case" "$(title_state zpool "78% Full")" "zpool: 78% Full"
is "state with a mark"    "$(title_state Backup Failed "$(title_mark restic)")" \
                          "Backup: Failed [restic]"
is "a bare quotation"     "$(title_quote Kene)"                     "Kene"
is "a quotation with a position" "$(title_quote Kene "$(title_pos 2 4)")" "Kene [2/4]"
is "a lone event has no position" "$(title_quote Kene "$(title_pos 1 1)")" "Kene"
is "a quotation nudges by age"   "$(title_quote Kene "$(title_age 31)")"  "Kene [1d]"

# The age scale. Coarse because both pipelines nudge exactly once and the nightly
# sweep pins the value between 24h and 48h — a precise number would report sweep
# timing rather than urgency.
echo "title_age"
is "hours below a day"  "$(title_age 6)"   "[6h]"
is "a day at 24h"       "$(title_age 24)"  "[1d]"
is "still days at 47h"  "$(title_age 47)"  "[1d]"
is "weeks past a fortnight" "$(title_age 400)" "[2w]"

# Rule 14: the cap exists so WE choose what survives, and the verb is never it.
echo "truncation"
long_title="$(title_count Finished 1 Track "Godspeed You! Black Emperor - Storm (Live at the Fillmore)")"
has   "the verb survives"        "$long_title" "Finished: "
has   "and the name is cut"      "$long_title" "…"
is    "at the cap"               "${#long_title}" "40"
hasnt "no three-dot ellipsis"    "$long_title" "..."
short="$(title_count Finished 1 Track "Artist - Track")"
is    "a short name is untouched" "$short" "Finished: Artist - Track"
# A bracket must never be what gets cut: it carries the position or the age.
marked="$(title_quote "A Really Very Long Event Title That Overruns" "$(title_pos 2 4)")"
has   "a bracket survives truncation" "$marked" "[2/4]"

# ------------------------------------------------------------------ paused cause
# paused_cause matches ai_reason()'s OUTPUT, which lives in another file. Asserting
# against ai_reason() directly rather than against a copy of its wording is what
# stops the two drifting: change the sentence there and this fails here.
echo "paused cause"
is "rc 3 is unpaid"       "$(paused_cause "$(ai_reason 3)")"                  "Unpaid"
is "rc 2 is unreachable"  "$(paused_cause "$(ai_reason 2)")"                  "Unreachable"
is "both at once is mixed" "$(paused_cause "$(ai_reason 2)" "$(ai_reason 3)")" "Mixed"
is "an unknown reason names nothing" "$(paused_cause "Something else entirely")" ""
is "no reasons name nothing"         "$(paused_cause)"                         ""
is "the title carries the cause" \
   "$(paused_title 3 Document "$(paused_cause "$(ai_reason 3)")")" \
   "Model Paused: 3 Documents [Unpaid]"
is "and reads as the model class"    "$(paused_title 1 Screenshot)" "Model Paused: 1 Screenshot"

# ------------------------------------------------------------------ the kinds
# Every job reaches the wire through a KIND, and the kind is what makes the lifecycle
# rules structural rather than remembered. These assert the SHAPES — which arguments
# exist, and what each wrapper does with them — because that is the entire value:
# tags were dropped in the same change, so no kind renders differently.
echo "kinds"
kind_trace() {
    (
        retract() { printf 'RETRACT %s\n' "${1:-}"; }
        notify()  { printf 'NOTIFY t=[%s] b=[%s] a=[%s] id=[%s]\n' \
                        "${1:-}" "${2:-}" "${3:-}" "${4:-}"; }
        "$@"
    )
}

is "a receipt has no actions and no id" \
   "$(kind_trace notify_receipt "Baked: 3 Rotations" body)" \
   "NOTIFY t=[Baked: 3 Rotations] b=[body] a=[] id=[]"
is "a fault may carry a stable id" \
   "$(kind_trace notify_fault "zpool: 78% Full" body disk-full)" \
   "NOTIFY t=[zpool: 78% Full] b=[body] a=[] id=[disk-full]"
is "a fault never carries actions" \
   "$(kind_trace notify_fault "zpool: 78% Full" body)" \
   "NOTIFY t=[zpool: 78% Full] b=[body] a=[] id=[]"
is "a proposal threads both" \
   "$(kind_trace notify_proposal "Staged: 3 Documents" body acts rec-1)" \
   "NOTIFY t=[Staged: 3 Documents] b=[body] a=[acts] id=[rec-1]"

# THE NUDGE RETRACTS FIRST, under the same id, so the phone ends up with one message
# rather than two. Seven call sites used to write that retract by hand immediately
# above their notify; doing it in the wrapper is one fewer thing to forget.
is "a nudge retracts before publishing" \
   "$(kind_trace notify_nudge "Still Staged: 3 Documents [1d]" body batch acts)" \
   "RETRACT batch
NOTIFY t=[Still Staged: 3 Documents [1d]] b=[body] a=[acts] id=[batch]"
is "and its actions are optional" \
   "$(kind_trace notify_nudge "Still Flagged: Kene [1d]" body rec-1)" \
   "RETRACT rec-1
NOTIFY t=[Still Flagged: Kene [1d]] b=[body] a=[] id=[rec-1]"
is "a resolution does the same" \
   "$(kind_trace notify_resolved "Binned: 1 Document" body rec-1 acts)" \
   "RETRACT rec-1
NOTIFY t=[Binned: 1 Document] b=[body] a=[acts] id=[rec-1]"

# The REQUIRED arguments are what make the rules impossible to break rather than
# forbidden: buttons with no id would be a decision nothing could ever withdraw.
is "a proposal refuses a missing id"     "$(kind_trace notify_proposal t b acts 2>/dev/null; echo rc=$?)" "rc=1"
is "a nudge refuses a missing id"        "$(kind_trace notify_nudge t b 2>/dev/null; echo rc=$?)"         "rc=1"
is "a receipt refuses a missing body"    "$(kind_trace notify_receipt t 2>/dev/null; echo rc=$?)"         "rc=1"

# notify() itself no longer takes a priority or a tag. Both were removed on
# 2026-08-20: priority had one legal value, and tags were twelve glyphs of which four
# meant "something is wrong". Asserting the HEADERS is what proves it, because a
# leftover argument would otherwise just be ignored.
echo "envelope"
# The shadow prints to STDERR: notify()'s real curl line ends in `>/dev/null`, which
# would swallow anything written to stdout and make every assertion below vacuously
# pass on an empty string.
hdr_probe() { bash -c '
    source /zpool/catallenya/ntfy/ntfy.lib.sh
    curl() { printf "%s\n" "$@" >&2; }
    _ntfy_env() { TAILNET_DOMAIN=x; TAILNET_DNS_NAME=y; NTFY_REVERSE_PROXY_PORT=1; }
    ntfy_muted() { return 1; }
    NTFY_TOPIC=t notify "title" "body" "" ""' 2>&1; }
hdrs="$(hdr_probe)"
hasnt "no Tags header"      "$hdrs" "Tags:"
hasnt "no Priority header"  "$hdrs" "Priority:"
has   "still a Title"       "$hdrs" "Title: title"
# NTFY_MARKDOWN went the same way on 2026-08-21: a per-consumer opt-out whose five
# users all build their bodies with the escaping renderers now, leaving a variable
# nothing set — a slot waiting for someone to put `no` in it. Rendering must be
# unconditional, because md_escape's whole purpose is guarding a RENDERED body.
has   "Markdown always on"  "$hdrs" "Markdown: yes"
is    "and cannot be turned off" \
    "$(NTFY_MARKDOWN=no hdr_probe | grep -c 'Markdown: yes')" "1"

# ------------------------------------------------------------------ bodies
# Every device quirk below was learned on the actual phone and was being COPY-PASTED
# between pipelines before it lived here — the same drift signature that produced four
# copies of notify(). These pin the bytes, because that is what the quirks are about.
echo "body_list"
one="$(body_list "a.txt")"
is    "a bare item is numbered"     "$one" "1\\. a.txt"
# NOT a real markdown list: the Android app renders genuine ordered-list markers as
# unnumbered dots, so the numbers — the thing that lets you check a list against the
# count in the title — silently vanish.
has   "the marker is escaped"       "$one" '1\. '
hasnt "and is not a real list"      "$one" $'\n1. '

pair="$(body_list "IMG_1234.jpg"$'\t'"rotated 90°")"
has   "a detail is indented"        "$pair" "rotated 90"
# NBSP+space pairs, NOT ordinary spaces: the ntfy web renderer collapses ordinary
# leading whitespace, so a plain-space indent vanishes there while looking right on
# Android.
has   "with NBSPs, not spaces"      "$pair" $'\u00a0'
hasnt "no four-space indent"        "$pair" $'\n    '
# A markdown HARD BREAK, without which the detail joins the name into one paragraph.
has   "and a hard break above it"   "$pair" "  "$'\n'

# Untrusted text reaches these: a camera filename is mostly underscores, and a name
# arriving over Syncthing could carry a live link. This is the whole reason
# NTFY_MARKDOWN existed, and why it can now go.
esc="$(body_list "photo_2026_08_01.jpg" "[tap here](https://evil.example)")"
has   "underscores are escaped"     "$esc" 'photo\_2026\_08\_01.jpg'
hasnt "and a link cannot render"    "$esc" '](https://evil.example)'

capped="$(body_list a b c d e f g)"
has   "capped at five"              "$capped" "5\\. e"
hasnt "the sixth is not listed"     "$capped" "6\\. f"
has   "and the rest are counted"    "$capped" "… and 2 more"
# --all is for the one list that must show everything: pigeonhole's staged batch,
# whose Accept files ALL of them. Showing 5 of 12 above a button that acts on 12
# means approving seven documents you never saw.
allof="$(body_list --all a b c d e f g)"
has   "--all shows every item"      "$allof" "7\\. g"
hasnt "and counts nothing off"      "$allof" "and 2 more"

# WHAT THE ESCAPING STOPS, AND WHAT IT DOES NOT. Markdown is on for every body, so
# these are the boundary, not a detail. Link SYNTAX is neutralised in everything the
# box did not author, because it HIDES its destination behind friendly text inside a
# notification the reader already trusts. A BARE URL is deliberately left alone — it
# shows where it goes, escaping one would mean mangling `:` and `/`, and
# changedetection's body ends with a real one on purpose.
# THE ONE DUPLICATED CONSTANT IN THE SYSTEM, pinned here because a second copy is
# how two things that must agree stop agreeing. restic/restic.lib.sh defines its own
# RESTIC_FACT_MARK: those jobs do not notify (the courier does), so sourcing the whole
# ntfy transport to read one character would be the mistake liquidroom made when it
# sourced the entire AI layer to reach two functions about ntfy.
echo "the marker restic copies"
is "restic's copy matches BODY_FACT_MARK" \
   "$(sed -nE "s/^RESTIC_FACT_MARK='(.*)'$/\\1/p" /zpool/catallenya/restic/restic.lib.sh)" \
   "$BODY_FACT_MARK"

echo "escaping boundary"
evil="$(body_list "[tap here](https://evil.example)")"
has   "link syntax is inert"        "$evil" '\[tap here\]'
hasnt "and cannot render a link"    "$evil" '](https://evil.example)'
has   "bold is inert too"           "$(body_list '**bold**')" '\*\*bold\*\*'
has   "and a heading"               "$(body_list '# heading')" '\# heading'
has   "and a code span"             "$(body_list '`code`')"    '\`code\`'
is    "a bare URL passes through"   "$(body_fact "see https://example.com/x")" \
      $'\u2022 see https://example.com/x'
# body_join escapes NOTHING — its arguments are already rendered, and escaping twice
# turns `1\.` into `1\\.`. That makes PROSE the caller's to escape, which is why the
# gate refuses hand-written link syntax.
is    "prose reaches the wire as written" "$(body_join "" "" "**not escaped**")" "**not escaped**"

echo "body_fact"
facts="$(body_fact "1.3T of 1.7T used" "400G free")"
is    "one line per fact"           "$facts" $'\u2022 1.3T of 1.7T used\n\u2022 400G free'
# U+2022 BULLET since 2026-08-22. It replaced U+25AA BLACK SMALL SQUARE, which has an
# EMOJI PRESENTATION — some Android builds drew it as a coloured square, and a marker
# that renders as an emoji on the device it is read on is not a marker.
#
# The bullet's whole advantage is that it needs NO ESCAPE: `-`, `*` and `+` are real
# markdown list markers and would be restyled, which is the trap the escaped `1\.`
# exists for. These pin that the marker never becomes one of those and never acquires
# a backslash, which would show literally on a device honouring the escape differently.
hasnt "never a hyphen list"         "$facts" $'\n- '
hasnt "never an asterisk list"      "$facts" $'\n* '
hasnt "and needs no escaping"       "$facts" '\\'
# No full stop on any line but prose (settled 2026-08-21): a stop after a path reads
# as part of the filename, and one rule beats remembering which line you are on.
is    "no trailing full stop"       "$(body_fact "400G free")" $'\u2022 400G free'
is    "empty args yield nothing"    "$(body_fact "")" ""
has   "text is escaped"             "$(body_fact "a_b_c")" 'a\_b\_c'

echo "body_join"
# The order rule is items, blank, facts, blank, prose. `$( )` strips trailing
# newlines, so a section boundary needs TWO literal newlines and looks like a typo
# with one — which is exactly why callers do not write it themselves any more.
joined="$(body_join "1\\. a" "$(body_fact "400G free")" "It may be full.")"
is    "sections separated by a blank" "$joined" $'1\\. a\n\n• 400G free\n\nIt may be full.'
is    "an empty section is dropped"   "$(body_join "" "$(body_fact "400G free")" "")" $'\u2022 400G free'
is    "nothing at all yields nothing" "$(body_join "" "" "")" ""
has   "one section is left alone"     "$(body_join "just this")" "just this"
hasnt "and gains no blank line"       "$(body_join "just this")" $'\n'

echo "body_aside"
is    "wrapped in italics"          "$(body_aside "3 more still queued")" "_3 more still queued_"
is    "empty text yields nothing"   "$(body_aside "")" ""
# Escaped BEFORE the wrapping underscores are added, so a name inside cannot break out
# of the emphasis and leave the rest of the body italic.
has   "text is escaped inside"      "$(body_aside "a_b_c")" 'a\_b\_c'

# ======================================================== system-ntfy.sh
# The courier every OnFailure= points at — and until 2026-08-24 the only thing in
# this fleet with NO behavioural test at all, which is how it spent a year able to
# title a failed run "Succeeded" without anyone noticing.
#
# It sources nothing on purpose (the alarm of last resort depends on nothing), so it
# is driven here through PATH stubs for systemctl and journalctl, with NTFY_DISABLE=1
# turning the publish into a printed "(title -> topic)" line. Everything up to the
# wire — ownership, topic routing, title derivation — runs for real.
echo
echo "system-ntfy: the courier"

CT="${TMP:-$(mktemp -d)}/courier"; mkdir -p "${CT}/bin"
cat > "${CT}/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"-p FragmentPath"*)   echo "/zpool/catallenya/restic/backup/restic.backup.service" ;;
  *"-p InvocationID"*)   echo "${STUB_INV:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" ;;
  cat\ *)                printf '[Service]\n[X-Catallenya]\nClass=scheduled\n' ;;
  is-failed*)            exit "${STUB_ISFAILED_RC:-1}" ;;   # 0 = unit is failed
  status*)               echo "stub status output" ;;
  *)                     exit 0 ;;
esac
STUB
cat > "${CT}/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
echo "journal line for ${*: -1}"
STUB
chmod +x "${CT}/bin/systemctl" "${CT}/bin/journalctl"

courier() {  # $1 unit; env: MONITOR_SERVICE_RESULT, STUB_ISFAILED_RC
    PATH="${CT}/bin:$PATH" NTFY_DISABLE=1 \
        bash "${SELF_DIR}/../system-ntfy.sh" "$1" 2>&1 || true
}

# THE REGRESSION. is-failed answers "is it failed NOW", and a .path-driven job is
# already `activating` again by the time the courier asks — so the honest answer to
# "did the run that triggered me fail" has to come from systemd's MONITOR_* instead.
echo "  the title reflects the INVOCATION, not the unit's current state"
out="$(MONITOR_SERVICE_RESULT=exit-code STUB_ISFAILED_RC=1 courier restic.backup)"
has "a failed invocation says Failed even while the unit reads healthy" "$out" "Failed"
hasnt "and never says Succeeded"                                        "$out" "Succeeded"

out="$(MONITOR_SERVICE_RESULT=success STUB_ISFAILED_RC=1 courier restic.backup)"
has "a successful invocation says Succeeded"                            "$out" "Succeeded"

# Other results are failures too — signal, timeout, oom-kill. Treating only
# "exit-code" as failure would call an OOM kill a success.
for r in signal timeout oom-kill core-dump watchdog; do
    out="$(MONITOR_SERVICE_RESULT="$r" STUB_ISFAILED_RC=1 courier restic.backup)"
    has "result '${r}' is a failure" "$out" "Failed"
done

# The fallback matters: systemd REFUSES to set MONITOR_* when a handler has more than
# one trigger source, and it counts OnSuccess= and OnFailure= on the same instance as
# two — which is exactly the three restic jobs. They are timer-driven and cannot
# re-trigger themselves, so is-failed is still right for them, but it must still work.
echo "  falls back to is-failed when MONITOR_* is absent"
out="$(STUB_ISFAILED_RC=0 courier restic.backup)"
has "unit failed  -> Failed"    "$out" "Failed"
out="$(STUB_ISFAILED_RC=1 courier restic.backup)"
has "unit healthy -> Succeeded" "$out" "Succeeded"

echo "  topic routing still holds"
out="$(MONITOR_SERVICE_RESULT=success courier restic.backup)"
has "a known topic is used directly" "$out" "-> restic"
out="$(MONITOR_SERVICE_RESULT=exit-code courier notatopic.job)"
has "an unknown topic is REROUTED, never dropped" "$out" "-> host"

echo "  quiet on success: failures carry an id and leave a recovery marker"
FD="${CT}/faults"; rm -rf "$FD"
out="$(MONITOR_SERVICE_RESULT=exit-code NTFY_FAULT_DIR="$FD" courier restic.backup)"
has "a failure still publishes" "$out" "Backup: Failed -> restic"
m="${FD}/unit-restic.backup"
[[ -f "$m" ]] && ok "a failure leaves unit-<name> for recovered.sh" || bad "a failure leaves unit-<name> for recovered.sh" "$m" "absent"
is "the marker records the topic used"   "$(sed -n 2p "$m" 2>/dev/null)" "restic"
is "and the subject used"                "$(sed -n 3p "$m" 2>/dev/null)" "Backup"
rm -rf "$FD"
out="$(MONITOR_SERVICE_RESULT=success NTFY_FAULT_DIR="$FD" courier restic.backup)"
[[ ! -e "${FD}/unit-restic.backup" ]] && ok "a success leaves no marker" || bad "a success leaves no marker" "absent" "present"
out="$(MONITOR_SERVICE_RESULT=exit-code courier restic.backup)"
[[ ! -e "/zpool/catallenya/systemd/state/.faults/unit-restic.backup" || -n "${CI_KEEP_LIVE:-}" ]] \
    && ok "a muted run with no seam writes no live marker" \
    || bad "a muted run with no seam writes no live marker" "absent" "present in live state"

echo "  the daily self-test"
out="$(HEALTHCHECKS_COURIER_PING_URL=https://hc.invalid/x courier --selftest)"
has "publishes to the unsubscribed canary topic" "$out" "self-test -> courier-canary"
hasnt "and is never a job alert" "$out" "Failed"

# ======================================================== fault lifecycle
# fault_open / fault_close (ntfy.lib.sh): a repeating fault that clears on its own
# turns its message into the recovery, in place, on the same sequence id. notify is
# overridden in a subshell so what WOULD be published can be read back.
echo
echo "fault lifecycle"
FL="$(mktemp -d)"
lifecycle() {  # runs "$@" with the marker seam and a recording notify
    # The recording goes to a FILE, not stdout: the real notify is silent on success,
    # and fault_close reads any output as an undelivered publish.
    : > "${FL}.pub"
    ( NTFY_FAULT_DIR="$FL" NTFY_TOPIC=grayjay
      notify() { printf 'PUBLISH title=%s id=%s body=%s\n' "$1" "${4:-}" "${2//$'\n'/|}" >> "${FL}.pub"; }
      "$@" )
    cat "${FL}.pub"
}
out="$(lifecycle fault_open grayjay-archivebox "ArchiveBox: Unreachable" "b")"
has "fault_open publishes the fault on its stable id" "$out" "title=ArchiveBox: Unreachable id=grayjay-archivebox"
[[ -f "${FL}/grayjay.grayjay-archivebox" ]] && ok "and leaves a marker keyed on topic + id" \
    || bad "and leaves a marker keyed on topic + id" "${FL}/grayjay.grayjay-archivebox" "absent"
out="$(lifecycle fault_close grayjay-archivebox Reachable "Handed over again.")"
has "fault_close publishes the recovery on the SAME id" "$out" "title=ArchiveBox: Reachable id=grayjay-archivebox"
has "saying when it was first reported" "$out" "First reported"
has "with the caller's sentence" "$out" "Handed over again."
[[ ! -e "${FL}/grayjay.grayjay-archivebox" ]] && ok "and removes the marker" || bad "and removes the marker" "absent" "present"
out="$(lifecycle fault_close grayjay-archivebox Reachable)"
is "a second clean run says nothing" "$out" ""
out="$(lifecycle fault_close never-opened Reachable)"
is "nothing was reported, nothing to recover" "$out" ""
lifecycle fault_open containers "Containers: 3 Findings" "b" >/dev/null
out="$(lifecycle fault_close containers Running)"
has "a count title recovers under its subject" "$out" "title=Containers: Running"
# The four audit fixes (2026-10-31).
printf '%s\n%s\n' 1000 "ArchiveBox: Unreachable" > "${FL}/grayjay.ab"
lifecycle fault_open ab "ArchiveBox: Unreachable" "b" >/dev/null
is "a repeating fault keeps its FIRST timestamp" "$(head -1 "${FL}/grayjay.ab")" "1000"
# shellcheck disable=SC2034  # read by fault_close / _fault_marker inside this subshell
out="$( NTFY_FAULT_DIR="$FL" NTFY_TOPIC=grayjay NTFY_DISABLE=""   # a muted run counts as delivered
        notify() { echo "curl: (22) The requested URL returned error: 502" >&2; }
        fault_close ab Reachable 2>&1 )"
has "an undelivered recovery speaks, so the reporter fails its unit" "$out" "502"
[[ -f "${FL}/grayjay.ab" ]] && ok "…and puts the marker back for the next clean run" \
    || bad "…and puts the marker back for the next clean run" "present" "absent"
is "…with the original time intact" "$(head -1 "${FL}/grayjay.ab" 2>/dev/null)" "1000"
rm -f "${FL}/grayjay.ab"
lifecycle fault_open shop "Shop: Item: Broken" "b" >/dev/null
out="$(lifecycle fault_close shop Working)"
has "a subject containing ': ' survives into the recovery" "$out" "title=Shop: Item: Working"
mkdir -p "${FL}/ro"; lifecycle fault_open lock "Lock: Broken" "b" >/dev/null
mv "${FL}/grayjay.lock" "${FL}/ro/grayjay.lock"; chmod 500 "${FL}/ro"
# shellcheck disable=SC2034  # read by fault_close / _fault_marker inside this subshell
out="$( NTFY_FAULT_DIR="${FL}/ro" NTFY_TOPIC=grayjay
        notify() { echo PUBLISHED >> "${FL}.pub"; }
        : > "${FL}.pub"; fault_close lock Fixed 2>&1; cat "${FL}.pub" )"
is "a marker it cannot delete is never announced (no every-run repeat)" "$out" ""
chmod 700 "${FL}/ro"
# shellcheck disable=SC2034  # read by fault_close / _fault_marker inside this subshell
out="$( NTFY_TOPIC=grayjay; unset NTFY_FAULT_DIR; _fault_marker x || echo refused )"
is "a muted run with no seam refuses to name a live marker" "$out" "refused"
rm -rf "$FL"

# ======================================================== recovered.sh
# Runs after every successful job (10-base.conf ExecStartPost). The common case is no
# marker, which must cost nothing and print nothing.
echo
echo "recovered.sh"
RD="$(mktemp -d)"
out="$(NTFY_FAULT_DIR="$RD" bash "${SELF_DIR}/../recovered.sh" restic.backup 2>&1; echo "rc=$?")"
is "no marker: silent, exit 0" "$out" "rc=0"
printf '%s\n%s\n%s\n%s\n' "$(date +%s)" restic Backup "" > "${RD}/unit-restic.backup"
NTFY_FAULT_DIR="$RD" bash "${SELF_DIR}/../recovered.sh" restic.backup >/dev/null 2>&1; rc=$?
is "with a marker it still exits 0" "rc=$rc" "rc=0"
[[ ! -e "${RD}/unit-restic.backup" ]] && ok "and consumes the marker" || bad "and consumes the marker" "absent" "present"
out="$(bash "${SELF_DIR}/../recovered.sh" restic.backup 2>&1; echo "rc=$?")"
is "a muted run with no seam touches nothing" "$out" "rc=0"
mkdir -p "${RD}/ro"; printf '%s\n%s\n%s\n%s\n' 1 restic Backup "" > "${RD}/ro/unit-restic.backup"; chmod 500 "${RD}/ro"
out="$(NTFY_FAULT_DIR="${RD}/ro" bash "${SELF_DIR}/../recovered.sh" restic.backup 2>&1; echo "rc=$?")"
has "a marker it cannot delete is not announced" "$out" "not announcing"
has "…and the job still succeeds" "$out" "rc=0"
chmod 700 "${RD}/ro"
rm -rf "$RD"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
