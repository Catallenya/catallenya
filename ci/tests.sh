#!/usr/bin/env bash
# Every test suite in the repo, defined ONCE, run by the ci/pre-push hook.
#
# HOOK-ONLY, AND THAT IS NOT A CHOICE — it is a measurement. Unlike ci/contract.sh
# and ci/shellcheck.sh beside it, this cannot be a CI job: every suite here resolves
# /zpool/catallenya absolutely and deliberately (systemd/heartbeat.sh sources the
# transport by absolute path with a comment saying why; ntfy/system-ntfy.sh reads the
# root .env the same way). Run in a container with no /zpool on 2026-08-23, six of
# the seven fail in bulk and the seventh cannot start. Making them portable means
# changing how production scripts find themselves to satisfy a runner, which is a
# real risk taken for a second-order gain. So they run here, on the machine where
# their assumptions are true.
#
# THE COST IS REAL AND WAS CHOSEN WITH THE NUMBER IN FRONT OF US. Measured on this
# box: 131s for all seven, against 1.7s for the contract gate and 5.9s for the shell
# check. A push therefore takes a little over two minutes.
#
# (That line is worded around a trap: a comment whose first word after `#` is
# "shellcheck" is parsed as a DIRECTIVE, and shellcheck then fails the file with
# SC1073 rather than reading it as prose.)
#
# That runs against ci/pre-push's own warning — "a check that fires on every docs
# typo is a check people learn to skip with --no-verify, which would cost the secret
# guard its credibility too, since that is the same flag." The warning still stands
# and is the thing to watch. If two minutes on a docs commit starts producing
# --no-verify, the fix is to SCOPE this to the suites whose directories changed
# (measured: ~8s for a docs push), not to delete it. Do that before reaching for the
# flag even once.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# FASTEST FIRST, so a failure surfaces as early as it can. Measured 2026-08-23:
#   ntfy 0.2s · host 0.9s · liquidroom 2.6s · afterimage 3.2s
#   ai 8.4s · pigeonhole 43.3s · systemd 72.3s
# The last two are 88% of the wall clock for 31% of the tests.
#
# HARDCODED, NOT GLOBBED, for the reason host/smart.sh hardcodes its device list: a
# glob that matches fewer suites than yesterday runs fewer tests and still exits 0 —
# a checker whose failure reads as success, which is the shape this repo hunts. A
# new suite is a deliberate line here. The guard below is what stops that becoming a
# way to forget one.
SUITES=(
    ntfy
    host
    liquidroom
    afterimage
    ai
    ebooks
    grayjay
    radicale/feeds
    pigeonhole
    systemd
)

# A suite that exists and is NOT in the list above would silently never run. Discover
# them and refuse the difference — the same argument install.sh makes for
# cross-checking its SYMLINKS map against the tree, and the same bug: a committed
# unit that was never registered validated nothing and reported "35 units satisfy
# the contract".
shopt -s nullglob
declare -a found=()
for f in */tests/run.sh */*/tests/run.sh; do found+=("${f%/tests/run.sh}"); done
shopt -u nullglob
for f in "${found[@]}"; do
    for s in "${SUITES[@]}"; do [[ "$f" == "$s" ]] && continue 2; done
    echo "ci/tests.sh: ${f}/tests/run.sh exists but is not in SUITES — it would never run." >&2
    echo "  Add it to the list in this file, or delete the suite. A test nobody runs" >&2
    echo "  is worse than no test: it reports coverage that is not there." >&2
    exit 1
done

start=$(date +%s)
fail=0
for s in "${SUITES[@]}"; do
    printf '  %-15s' "$s"
    t0=$(date +%s)
    if out="$(bash "${s}/tests/run.sh" 2>&1)"; then
        printf '%s  (%ss)\n' "$(tail -1 <<<"$out")" "$(( $(date +%s) - t0 ))"
    else
        # STOP HERE. With a two-minute budget, running the remaining suites after a
        # known failure spends the rest of it telling you something you already have
        # to act on. The output is printed whole: a suite's own failure lines name
        # the case, and truncating them would mean re-running it by hand to read
        # what this already knew.
        printf 'FAILED  (%ss)\n\n' "$(( $(date +%s) - t0 ))"
        printf '%s\n' "$out"
        fail=1
        break
    fi
done

printf '  %-15s%ss total\n' "" "$(( $(date +%s) - start ))"
exit "$fail"
