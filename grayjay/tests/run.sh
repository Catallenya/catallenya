#!/usr/bin/env bash
# Regression tests for the grayjay pipeline (Grayjay playlist backup -> ArchiveBox).
#
# Offline and free. Every case RUNS the real job — grayjay.archive.sh and the real
# grayjay.archive.py — against a scratch tree: GRAYJAY_BACKUP points at synthetic
# backups, GRAYJAY_STATE at a scratch state dir, GRAYJAY_DOCKER at a fake `docker` that
# keeps a pretend ArchiveBox in one JSON file, and GRAYJAY_NOW moves the clock. Nothing
# here reads the real backup, touches the real ArchiveBox or reaches the phone: the job
# is sourced in a subshell and `notify` is replaced with a recorder, and NTFY_DISABLE=1
# backs that up.
#
# The fake answers exactly the four things the job asks ArchiveBox (the Django-shell
# lookup, `add`, `extract`, and being down), and mimics the one behaviour the design
# rests on: ONLY_NEW makes `add` skip a URL that already has a snapshot WITHOUT tagging
# it. The helper that runs inside the real container (grayjay.abx.py) is not run here;
# it was checked read-only against the live ArchiveBox when written.
#
#   bash grayjay/tests/run.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(cd "${SELF_DIR}/../scripts" && pwd)"
REPO="$(cd "${SELF_DIR}/../.." && pwd)"

PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
is()   { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "$3" "$2"; }
has()  { [[ "$2" == *"$3"* ]] && ok "$1" || bad "$1" "contains $3" "$2"; }
hasnt(){ [[ "$2" != *"$3"* ]] && ok "$1" || bad "$1" "must not contain $3" "$2"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export NTFY_DISABLE=1 PYTHONDONTWRITEBYTECODE=1
# Recovery markers (ntfy.lib.sh fault_open/fault_close) go to scratch, never live state.
export NTFY_FAULT_DIR="${TMP}/faults"
export GRAYJAY_BACKUP="${TMP}/config/GrayjayBackup.ezip"
export GRAYJAY_STATE="${TMP}/state"
export GRAYJAY_DOCKER="${TMP}/docker"
FAKE="${TMP}/abx.json"
CAP="${TMP}/cap"
export FAKE

GUITAR="a359d200-8781-409e-b76a-ba0b6c3e58d5"
ADDISON="e46f4674-39b9-4d51-aee0-3b38758ac332"
T0=1792000000            # a fixed "now"; GRAYJAY_NOW moves from here
DAY=86400

# ------------------------------------------------------------------ the fake docker
cat > "$GRAYJAY_DOCKER" <<'PY'
#!/usr/bin/env python3
import json, os, sys, uuid
db_path = os.environ["FAKE"]
db = json.load(open(db_path))
args = sys.argv[1:]
db["calls"].append(args[:1] + [a for a in args[1:] if not a.startswith(("# Runs", "import"))][:40])
def done(rc=0):
    json.dump(db, open(db_path, "w"))
    sys.exit(rc)
if db.get("down"):
    print("Error response from daemon: container archivebox is not running", file=sys.stderr)
    done(1)
# `-u archivebox … archivebox archivebox <cmd>`: user, container, then the CLI itself.
cmd = args[len(args) - args[::-1].index("archivebox"):]
snaps = db["snapshots"]
def find(url, alt):
    if url in snaps:
        return url
    for a in alt:
        for u in sorted(snaps):
            if a in u:
                return u
    return None
if cmd[:3] == ["manage", "shell", "-c"]:
    req = json.loads(os.environ.get("GJ_REQ") or "{}")
    out = {}
    for it in req["items"]:
        u = find(it["url"], it.get("alt", []))
        if u is None:
            out[it["key"]] = {"exists": False}
            continue
        s = snaps[u]
        if req.get("apply_tags"):
            for t in it["tags"]:
                if t not in s["tags"]:
                    s["tags"].append(t)
        out[it["key"]] = {"exists": True, "id": s["id"], "status": s["status"],
                          "title": s["title"], "tags": sorted(s["tags"]), "ytdlp": s["ytdlp"]}
    print("25 objects imported automatically (use -v 2 for details).\n")
    print("GJ_RESULT=" + json.dumps(out))
    done()
if cmd[:1] == ["add"]:
    if db.get("add_fails"):
        print("add: database is locked", file=sys.stderr)
        done(1)
    tags = cmd[cmd.index("--tag") + 1].split(",")
    urls = [a for a in cmd[1:] if a.startswith("http")]
    for u in urls:
        if u in snaps:          # ONLY_NEW: skipped, and NOT tagged
            continue
        snaps[u] = {"id": uuid.uuid4().hex, "status": "queued", "title": "",
                    "tags": tags, "ytdlp": None}
    done()
if cmd[:1] == ["extract"]:
    for sid in cmd[1:]:
        for s in snaps.values():
            if s["id"] == sid:
                # A snapshot that never ran ytdlp (a page-only bookmark) gets a fresh result.
                s["ytdlp"] = dict(s["ytdlp"] or {"output": "", "notes": "", "files": []},
                                  status="queued")
    done()
print("fake docker: unexpected " + " ".join(args), file=sys.stderr)
done(99)
PY
chmod +x "$GRAYJAY_DOCKER"

abx_reset() { printf '{"snapshots": {}, "calls": []}\n' > "$FAKE"; }
# abx_snap <url> <status> <title> <tags,csv> [ytdlp-status] [output] [file...]
abx_snap() {
    python3 -I - "$FAKE" "$@" <<'PY'
import json, sys, uuid
p, url, status, title, tags, *rest = sys.argv[1:]
db = json.load(open(p))
y = None
if rest:
    y = {"status": rest[0], "output": rest[1] if len(rest) > 1 else "",
         "notes": "", "files": rest[2:]}
old = db["snapshots"].get(url, {})
db["snapshots"][url] = {"id": old.get("id") or uuid.uuid4().hex, "status": status,
                        "title": title, "tags": [t for t in tags.split(",") if t] or old.get("tags", []),
                        "ytdlp": y}
json.dump(db, open(p, "w"))
PY
}
abx() { jq -r "$1" "$FAKE"; }
abx_flag() { jq ".$1 = true" "$FAKE" > "$FAKE.t" && mv "$FAKE.t" "$FAKE"; }
abx_unflag() { jq "del(.$1)" "$FAKE" > "$FAKE.t" && mv "$FAKE.t" "$FAKE"; }
calls() { jq -r '.calls[] | select(.[0] == "exec") | map(select(startswith("GJ_REQ") | not)) | join(" ")' "$FAKE"; }
yt() { printf 'https://www.youtube.com/watch?v=%s' "$1"; }

# ---------------------------------------------------------------- backup builder
# mk_backup <path> [--junk] [--bad-header] "<name>:::<uuid>" url url -- "<name>:::<uuid>" url …
mk_backup() {
    python3 -I - "$@" <<'PY'
import io, json, sys, zipfile
path, *rest = sys.argv[1:]
junk = "--junk" in rest
badhdr = "--bad-header" in rest
rest = [r for r in rest if r not in ("--junk", "--bad-header")]
lists, cur = [], None
for r in rest:
    if r == "--":
        cur = None
    elif cur is None:
        cur = [r]
        lists.append(cur)
    else:
        cur.append(r)
entries = ["\n".join(l) for l in lists]
def build(entries, pad=b""):
    b = io.BytesIO()
    with zipfile.ZipFile(b, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("exportInfo", '{"version":"1"}')
        z.writestr("stores/Playlists", json.dumps(entries))
        z.writestr("stores/history", "watch history" + pad.decode())
    return b.getvalue()
hdr = b"BADHEADR" if badhdr else bytes.fromhex("11223344474a0100")
data = hdr + build(entries)
if junk:
    # Grayjay's in-place overwrite: an OLDER, LARGER backup's tail survives, EOCD and all.
    older = hdr + build(entries + ["Old:::x\nhttps://www.youtube.com/watch?v=zzzzzzzzzzz"], b"x" * 4000)
    data = data + older[len(data):]
open(path, "wb").write(data)
PY
}

fresh() {
    rm -rf "$GRAYJAY_STATE" "${TMP}/config" "$CAP" "$NTFY_FAULT_DIR"
    mkdir -p "${TMP}/config" "$CAP"
    : > "${CAP}/titles"; : > "${CAP}/bodies"
    abx_reset
}
age_backup() { # <days-old relative to NOW>
    local f t
    t=$(( NOW - $1 * DAY ))
    for f in "$GRAYJAY_BACKUP" "${GRAYJAY_BACKUP}.old"; do
        [[ -e "$f" ]] && touch -d "@${t}" "$f"
    done
    return 0
}

NOW=$T0
# run_job — the real entrypoint, in a subshell, with notify recorded instead of sent.
run_job() {
    (
        export GRAYJAY_NOW="$NOW"
        # shellcheck source=../scripts/grayjay.archive.sh
        source "${SCRIPT_DIR}/grayjay.archive.sh"
        # The synthetic backups carry only these two playlists. Pinning the allow-list
        # here keeps every case independent of how many playlists production follows;
        # the real list is checked on its own under "hygiene".
        PLAYLISTS=("${GUITAR}=Guitar" "${ADDISON}=AddisonCore")
        notify() {
            printf '%s\t%s\n' "$1" "${4:-}" >> "${CAP}/titles"
            printf '%s\n----\n' "$2" >> "${CAP}/bodies"
            [[ -z "${UNDELIVERED:-}" ]] || echo "curl: (22) The requested URL returned error: 502" >&2
        }
        retract() { :; }
        main
    ) > "${TMP}/out" 2> "${TMP}/err"
}
titles() { cut -f1 "${CAP}/titles"; }
ids()    { cut -f2 "${CAP}/titles"; }
bodies() { cat "${CAP}/bodies"; }
rec()    { jq -r "$2" "${GRAYJAY_STATE}/videos/$1.json" 2>/dev/null; }
clear_cap() { : > "${CAP}/titles"; : > "${CAP}/bodies"; }

standard_backup() {
    mk_backup "$GRAYJAY_BACKUP" \
        "Guitar:::${GUITAR}" "$(yt aaaaaaaaaaa)" "https://youtu.be/bbbbbbbbbbb?si=MMxwzAZj2svCz9HH" \
        -- "🐟 AddisonCore:::${ADDISON}" "$(yt ccccccccccc)" \
           "https://www.youtube.com/watch?v=ddddddddddd&list=RDddddddddddd&start_radio=1" "$(yt aaaaaaaaaaa)" \
        -- "Mastering:::0f5536d0-761e-4c80-84e6-6366f9478308" "$(yt eeeeeeeeeee)"
    age_backup 1
}

# ======================================================================= backfill
echo "backfill"
fresh
standard_backup
abx_snap "$(yt ccccccccccc)" sealed "Old Favourite - YouTube" "Random" succeeded "" "Old_Favourite.mp4"
run_job; rc=$?
is "a first run exits 0" "$rc" "0"
is "...and is silent: a hand-over is not news" "$(titles)" ""
c="$(calls)"
has "every new video is handed over, title+ytdlp only, in the background" "$c" "add --bg --tag Guitar --plugins title,ytdlp $(yt bbbbbbbbbbb)"
has "a video in BOTH playlists is handed over once, with both tags" "$c" "add --bg --tag AddisonCore,Guitar --plugins title,ytdlp $(yt aaaaaaaaaaa)"
has "a youtu.be ?si= link is handed over in canonical form" "$c" "$(yt bbbbbbbbbbb)"
hasnt "...its tracking parameter never reaches ArchiveBox" "$c" "si="
has "a radio-mix link is cut down to the one video" "$c" "$(yt ddddddddddd)"
hasnt "...because --yes-playlist would archive the whole mix" "$c" "list=RD"
hasnt "a playlist that is not allow-listed is ignored" "$c" "eeeeeeeeeee"
hasnt "an existing snapshot is never handed over again (dedup)" "$c" "add --bg --tag AddisonCore --plugins title,ytdlp $(yt ccccccccccc)"
is "...it is ADOPTED instead" "$(rec ccccccccccc .status)" "adopted"
is "...and gains the playlist tag add --tag could never give it" "$(abx ".snapshots[\"$(yt ccccccccccc)\"].tags | join(\",\")")" "Random,AddisonCore"
is "handed-over videos are recorded pending" "$(rec bbbbbbbbbbb .status)" "pending"
is "four records, one per video" "$(find "$GRAYJAY_STATE/videos" -name '*.json' | wc -l)" "4"
has "the journal line counts the run" "$(cat "${TMP}/out")" "3 handed over"

hasnt "...and an adopted snapshot that holds the video is never re-downloaded" "$(calls)" " extract "

echo "adopting a snapshot WITHOUT the video (live 2026-11-01)"
# Two playlist videos had been saved as 2025 bookmarks: the web page, no video. Adoption
# used to count that as done. Now it is downloaded, on the same snapshot, silently.
fresh
standard_backup
abx_snap "$(yt ccccccccccc)" sealed "Page Only - YouTube" "Random"
run_job
is "a page-only snapshot is NOT adopted" "$(rec ccccccccccc .status)" "pending"
c="$(calls)"
has "...ytdlp is run on that same snapshot" "$c" "extract --plugins ytdlp --no-wait $(abx ".snapshots[\"$(yt ccccccccccc)\"].id")"
hasnt "...it is never handed over as a second snapshot" "$c" "add --bg --tag AddisonCore --plugins title,ytdlp $(yt ccccccccccc)"
is "...and it is silent: no failure was ever announced" "$(titles)" ""
is "...it keeps its old tag and gains the playlist's" "$(abx ".snapshots[\"$(yt ccccccccccc)\"].tags | join(\",\")")" "Random,AddisonCore"
has "the journal line counts it as backfilled" "$(cat "${TMP}/out" "${TMP}/err")" "1 backfilled"
has "...and not as a retry of something that failed" "$(cat "${TMP}/out" "${TMP}/err")" "0 retried"
is "...no failure clock was started" "$(rec ccccccccccc .first_failed_at)" "null"
abx_snap "$(yt ccccccccccc)" sealed "Page Only - YouTube" "" succeeded "" "Page_Only.webm"
clear_cap
run_job
is "when the download lands, it is archived" "$(rec ccccccccccc .status)" "archived"
is "...silently, because you were never told it failed" "$(titles)" ""

fresh
standard_backup
abx_snap "$(yt ccccccccccc)" sealed "Page Only - YouTube" "Random"
run_job
abx_snap "$(yt ccccccccccc)" sealed "Page Only - YouTube" "" failed "Sign in to confirm your age"
NOW=$((T0 + DAY)); run_job; NOW=$T0
has "a backfill that then FAILS is announced like any other failure" "$(titles)" "Dropped"

echo "a record adopted before this rule is re-checked"
fresh
standard_backup
abx_snap "$(yt ccccccccccc)" sealed "Page Only - YouTube" "Random"
mkdir -p "$GRAYJAY_STATE/videos"
printf '{"key":"ccccccccccc","url":"%s","alt":[],"tags":["AddisonCore"],"status":"adopted","snapshot_id":"%s","title":"Page Only","first_seen_at":%s}\n' \
    "$(yt ccccccccccc)" "$(abx ".snapshots[\"$(yt ccccccccccc)\"].id")" "$T0" > "$GRAYJAY_STATE/videos/ccccccccccc.json"
run_job
is "an old adopted record with no video becomes pending" "$(rec ccccccccccc .status)" "pending"
has "...and ytdlp is asked for it" "$(calls)" "extract --plugins ytdlp --no-wait"
is "...silently" "$(titles)" ""

echo "second run, nothing new"
abx_reset_calls() { jq '.calls = []' "$FAKE" > "$FAKE.t" && mv "$FAKE.t" "$FAKE"; }
abx_reset_calls
run_job
hasnt "a video already handed over is not handed over again" "$(calls)" " add "
is "...and still-downloading videos are silent" "$(titles)" ""

echo "silence when things work"
abx_snap "$(yt aaaaaaaaaaa)" sealed "First Video - YouTube" "" succeeded "ytdlp/First_Video.mkv" "First_Video.mkv" "First_Video.info.json"
run_job
is "a video that saves is SILENT: the phone hears only problems (owner, 2026-10-31)" "$(titles)" ""
is "...but it is recorded archived" "$(rec aaaaaaaaaaa .status)" "archived"
abx_snap "$(yt bbbbbbbbbbb)" sealed "Second - YouTube" "" succeeded "x" "Second.webm"
abx_snap "$(yt ddddddddddd)" sealed "Third - YouTube" "" succeeded "x" "Third.mp4"
run_job
is "several saving together are silent too" "$(titles)" ""
has "...and the journal still counts them" "$(cat "${TMP}/out")" "2 archived"

# ===================================================================== the backup
echo "backup parsing"
fresh
mk_backup "$GRAYJAY_BACKUP" --junk "Guitar:::${GUITAR}" "$(yt aaaaaaaaaaa)" -- "AddisonCore:::${ADDISON}"
age_backup 1
run_job; rc=$?
is "a junk tail after the zip is cut away (Grayjay overwrites without truncating)" "$rc" "0"
has "...and the playlist inside is read" "$(calls)" "$(yt aaaaaaaaaaa)"
hasnt "...the OLD archive's playlist in the tail is not" "$(calls)" "zzzzzzzzzzz"

fresh
printf 'garbage' > "$GRAYJAY_BACKUP"
mk_backup "${GRAYJAY_BACKUP}.old" "Guitar:::${GUITAR}" "$(yt aaaaaaaaaaa)" -- "AddisonCore:::${ADDISON}"
age_backup 1
run_job; rc=$?
is "an unreadable main backup falls back to .old" "$rc" "0"
has "...and its videos are handed over" "$(calls)" "$(yt aaaaaaaaaaa)"
has "...and the journal says which file was used" "$(cat "${TMP}/out")" "from .old"
is "...silently" "$(titles)" ""

fresh
printf 'garbage' > "$GRAYJAY_BACKUP"
mk_backup "${GRAYJAY_BACKUP}.old" --bad-header "Guitar:::${GUITAR}" "$(yt aaaaaaaaaaa)"
age_backup 1
run_job; rc=$?
is "both files unreadable: Backup: Unreadable" "$(titles)" "Backup: Unreadable"
is "...on the stable backup id" "$(ids)" "grayjay-backup"
has "...saying neither could be opened" "$(bodies)" "Neither GrayjayBackup.ezip nor its .old copy could be opened"
is "...and the run FAILS (a worker that could not work)" "$( ((rc != 0)) && echo yes)" "yes"
hasnt "...handing nothing over" "$(calls)" " add "

fresh
run_job; rc=$?
is "no backup at all is Unreadable too" "$(titles)" "Backup: Unreadable"
has "...and says the file is missing" "$(bodies)" "No backup file exists"

echo "playlists"
fresh
mk_backup "$GRAYJAY_BACKUP" "Guitar:::${GUITAR}" "$(yt aaaaaaaaaaa)"
age_backup 1
run_job; rc=$?
is "an allow-listed UUID absent from the backup: <Tag>: Missing" "$(titles)" "AddisonCore: Missing"
is "...on a per-tag stable id" "$(ids)" "grayjay-missing-AddisonCore"
has "...naming the UUID" "$(bodies)" "$ADDISON"
is "...a finding about the world, so the run still succeeds" "$rc" "0"
has "...and the playlist that IS there is still handled" "$(calls)" "$(yt aaaaaaaaaaa)"

clear_cap; abx_reset_calls
mk_backup "$GRAYJAY_BACKUP" "Guitar Licks (renamed):::${GUITAR}" "$(yt aaaaaaaaaaa)" -- "AddisonCore:::${ADDISON}"
age_backup 1
run_job
# AddisonCore is back in this backup, so the Missing from the run above recovers in
# place (the recovery rule); the RENAMED Guitar playlist itself adds nothing.
is "a renamed playlist (same UUID) changes nothing; the missing one is Found" "$(titles)" "AddisonCore: Found"
hasnt "...hands nothing over again" "$(calls)" " add "

echo "staleness"
fresh
standard_backup
age_backup 8
run_job; rc=$?
is "a backup older than 7 days: Backup: 8 Days Old" "$(titles)" "Backup: 8 Days Old"
is "...on the same stable id, so it rewrites itself daily" "$(ids)" "grayjay-backup"
has "...with when it was written" "$(bodies)" "Last backup"
has "...and what to do" "$(bodies)" "Open Grayjay on the phone to trigger one."
is "...a finding, not a failure" "$rc" "0"
clear_cap
age_backup 7
run_job
# Not stale any more, so the 8-day fault above recovers rather than staying silent.
is "exactly 7 days is not stale yet, so the stale fault recovers" "$(titles)" "Backup: Current"

# ===================================================================== failures
echo "failure policy"
fresh
mk_backup "$GRAYJAY_BACKUP" "Guitar:::${GUITAR}" "$(yt fffffffffff)" -- "AddisonCore:::${ADDISON}"
age_backup 1
run_job
abx_snap "$(yt fffffffffff)" sealed "Long Lesson - YouTube" "" failed "Timed out after 7200 seconds"
NOW=$(( T0 + DAY )); age_backup 1; abx_reset_calls
run_job; rc=$?
is "first failure: Dropped: 1 Video" "$(titles)" "Dropped: 1 Video"
has "...naming the video" "$(bodies)" "Long Lesson"
has "...with the reason, compact" "$(bodies)" "Timed out after 2h"
hasnt "...no full stop on the detail line" "$(bodies)" "after 2h."
is "...as a one-shot fault: no sequence id" "$(ids)" ""
has "...and it is retried at once, ytdlp only, on the SAME snapshot" "$(calls)" "extract --plugins ytdlp --no-wait $(abx ".snapshots[\"$(yt fffffffffff)\"].id")"
is "...a failed download is news about the world: exit 0" "$rc" "0"
first="$(rec fffffffffff .first_failed_at)"

clear_cap
abx_snap "$(yt fffffffffff)" sealed "Long Lesson - YouTube" "" failed "Timed out after 7200 seconds"
NOW=$(( T0 + 3 * DAY )); age_backup 1; abx_reset_calls
run_job
is "failing again: retried QUIETLY" "$(titles)" ""
has "...retried" "$(calls)" "extract --plugins ytdlp"
is "...and the clock still runs from the FIRST failure" "$(rec fffffffffff .first_failed_at)" "$first"

clear_cap
# 7.5 days after the HAND-OVER but only 6.5 after the first failure: not yet. This is the
# case that tells the two clocks apart.
abx_snap "$(yt fffffffffff)" sealed "Long Lesson - YouTube" "" failed "Timed out after 7200 seconds"
NOW=$(( T0 + 7 * DAY + DAY / 2 )); age_backup 1; abx_reset_calls
run_job
is "7.5 days after hand-over but 6.5 after the first failure: still retrying" "$(titles)" ""
has "...retried" "$(calls)" "extract --plugins ytdlp"

clear_cap
abx_snap "$(yt fffffffffff)" sealed "Long Lesson - YouTube" "" failed "Timed out after 7200 seconds"
NOW=$(( T0 + 8 * DAY )); age_backup 1; abx_reset_calls
run_job
is "7 days from the first failure: Abandoned: 1 Video" "$(titles)" "Abandoned: 1 Video"
has "...with the last reason" "$(bodies)" "Timed out after 2h"
has "...and how to try again" "$(bodies)" "put it back to try again"
hasnt "...and no further retry" "$(calls)" "extract"
is "...recorded abandoned" "$(rec fffffffffff .status)" "abandoned"
clear_cap; abx_reset_calls
NOW=$(( T0 + 9 * DAY )); age_backup 1
run_job
is "an abandoned video is never mentioned again" "$(titles)" ""
hasnt "...or handed over again" "$(calls)" "fffffffffff"

echo "a retry that succeeds"
fresh
mk_backup "$GRAYJAY_BACKUP" "Guitar:::${GUITAR}" "$(yt ggggggggggg)" -- "AddisonCore:::${ADDISON}"
NOW=$T0; age_backup 1
run_job
abx_snap "$(yt ggggggggggg)" sealed "Flaky - YouTube" "" failed "403 Forbidden"
NOW=$(( T0 + DAY )); age_backup 1
run_job
has "a plugin one-liner is the reason as given" "$(bodies)" "403 Forbidden"
clear_cap
abx_snap "$(yt ggggggggggg)" sealed "Flaky - YouTube" "" succeeded "x" "Flaky.mp4"
NOW=$(( T0 + 2 * DAY )); age_backup 1
run_job
is "a video you were told FAILED that later saves says so: Archived: <title>" "$(titles)" "Archived: Flaky"
has "...as the one good-news message" "$(bodies)" "It failed before and is now saved."
is "...a receipt: no sequence id" "$(ids)" ""

echo "what counts as a video"
fresh
mk_backup "$GRAYJAY_BACKUP" "Guitar:::${GUITAR}" "$(yt hhhhhhhhhhh)" "$(yt iiiiiiiiiii)" "$(yt jjjjjjjjjjj)" -- "AddisonCore:::${ADDISON}"
NOW=$T0; age_backup 1
run_job
# A timeout between yt-dlp's two streams leaves a finished video-only .fNNN. file, which
# the ytdlp plugin reports as SUCCEEDED. That is not an archived video.
abx_snap "$(yt hhhhhhhhhhh)" sealed "Half - YouTube" "" succeeded "ytdlp/Half.f299.mp4" "Half.f299.mp4" "Half.info.json"
abx_snap "$(yt iiiiiiiiiii)" sealed "Partial - YouTube" "" succeeded "ytdlp/Partial.description" "Partial.description" "Partial.m4a.part"
abx_snap "$(yt jjjjjjjjjjj)" sealed "Private - YouTube" "" failed $'yt-dlp error: [youtube] jjjjjjjjjjj: Downloading webpage\nERROR: [youtube] jjjjjjjjjjj: Private video. Sign in if you\'ve been granted access to this video.\n'
NOW=$(( T0 + DAY )); age_backup 1
run_job
is "succeeded-with-only-a-stream, a .part, and an error are all Dropped, not Archived" "$(titles)" "Dropped: 3 Videos"
has "an unmerged .fNNN. stream is 'did not finish'" "$(bodies)" "Download did not finish"
has "yt-dlp's own ERROR line is the reason, prefix stripped" "$(bodies)" "Private video"
hasnt "...without the [youtube] <id>: prefix" "$(bodies)" "jjjjjjjjjjj:"
# Both real shapes from the first backfill (2026-10-20). The files decide, in BOTH
# directions: "succeeded" holding only an audio stream and a .part is not archived,
# and "failed" with no message holding a complete merged file IS.
clear_cap
mk_backup "$GRAYJAY_BACKUP" "Guitar:::${GUITAR}" "$(yt nnnnnnnnnnn)" "$(yt ooooooooooo)" -- "AddisonCore:::${ADDISON}"
NOW=$T0; age_backup 1
run_job
abx_snap "$(yt nnnnnnnnnnn)" sealed "Guitar Cover - YouTube" "" succeeded "ytdlp/Guitar_Cover.f251.webm" "Guitar_Cover.description" "Guitar_Cover.f251.webm" "Guitar_Cover.f299.mp4.part" "Guitar_Cover.info.json"
abx_snap "$(yt ooooooooooo)" sealed "House Mix - YouTube" "" failed "" "House_Mix.description" "House_Mix.en.srt" "House_Mix.info.json" "House_Mix.webm" "House_Mix.webp"
NOW=$(( T0 + DAY )); age_backup 1; abx_reset_calls
run_job
hasnt "a 'failed' result holding a complete merged file is NOT Dropped" "$(bodies)" "House Mix"
is "...recorded archived" "$(rec ooooooooooo .status)" "archived"
hasnt "...and is not downloaded again" "$(calls)" "$(abx ".snapshots[\"$(yt ooooooooooo)\"].id")"
has "a 'succeeded' result with only an audio stream and a .part is DROPPED" "$(titles)" "Dropped: 1 Video"
has "...naming it" "$(bodies)" "Guitar Cover"
has "...as unfinished" "$(bodies)" "Download did not finish"

# Real output from the first live run (2026-10-19): an age-restricted video.
clear_cap
mk_backup "$GRAYJAY_BACKUP" "Guitar:::${GUITAR}" "$(yt mmmmmmmmmmm)" -- "AddisonCore:::${ADDISON}"
NOW=$T0; age_backup 1
run_job
abx_snap "$(yt mmmmmmmmmmm)" sealed "Gardening on Salvia - YouTube" "" failed $'yt-dlp error: [youtube] Extracting URL: https://www.youtube.com/watch?v=mmmmmmmmmmm\nERROR: [youtube] mmmmmmmmmmm: Sign in to confirm your age. Use --cookies-from-browser or --cookies for the authentication. See  https://github.com/yt-dlp/yt-dlp/wiki/FAQ#how-do-i-pass-cookies-to-yt-dlp  for how to manually pass cookies.\n'
NOW=$(( T0 + DAY )); age_backup 1
run_job
has "an age-restricted video says so in one sentence" "$(bodies)" "Sign in to confirm your age"
hasnt "...without yt-dlp's cookie advice" "$(bodies)" "cookies"

echo "lost hand-overs"
fresh
mk_backup "$GRAYJAY_BACKUP" "Guitar:::${GUITAR}" "$(yt kkkkkkkkkkk)" -- "AddisonCore:::${ADDISON}"
NOW=$T0; age_backup 1
run_job
abx_reset   # ArchiveBox lost the queued snapshot
NOW=$(( T0 + 3600 )); age_backup 1
run_job
is "a snapshot not there yet within a day is still pending" "$(titles)" ""
NOW=$(( T0 + 2 * DAY )); age_backup 1
run_job
is "...a day later it is a failure" "$(titles)" "Dropped: 1 Video"
has "...saying so" "$(bodies)" "ArchiveBox never created a snapshot"
has "...and it is handed over again" "$(calls)" "add --bg --tag Guitar --plugins title,ytdlp $(yt kkkkkkkkkkk)"

echo "second tag"
fresh
mk_backup "$GRAYJAY_BACKUP" "Guitar:::${GUITAR}" "$(yt lllllllllll)" -- "AddisonCore:::${ADDISON}"
NOW=$T0; age_backup 1
run_job
abx_snap "$(yt lllllllllll)" sealed "Both - YouTube" "" succeeded "x" "Both.mp4"
run_job
mk_backup "$GRAYJAY_BACKUP" "Guitar:::${GUITAR}" "$(yt lllllllllll)" -- "AddisonCore:::${ADDISON}" "$(yt lllllllllll)"
age_backup 1; clear_cap
run_job
is "a video added to the second playlist later gets the second tag" \
   "$(abx ".snapshots[\"$(yt lllllllllll)\"].tags | sort | join(\",\")")" "AddisonCore,Guitar"
is "...silently" "$(titles)" ""
is "...and its record says so" "$(rec lllllllllll '.tags | join(",")')" "AddisonCore,Guitar"
hasnt "...without a second hand-over" "$(jq -r '.calls[] | join(" ")' "$FAKE" | grep -c ' add ')" "2"

echo "removal and re-adding (owner, 2026-10-31)"
fresh
mk_backup "$GRAYJAY_BACKUP" "Guitar:::${GUITAR}" "$(yt ppppppppppp)" "$(yt qqqqqqqqqqq)" "$(yt rrrrrrrrrrr)" -- "AddisonCore:::${ADDISON}"
NOW=$T0; age_backup 1
run_job
abx_snap "$(yt ppppppppppp)" sealed "Keeps Failing - YouTube" "" failed "403 Forbidden"
abx_snap "$(yt rrrrrrrrrrr)" sealed "Saved One - YouTube" "Guitar" succeeded "x" "Saved.mp4"
NOW=$(( T0 + DAY )); age_backup 1
run_job
is "setup: the failing video was Dropped" "$(titles)" "Dropped: 1 Video"
# qqq is still downloading (queued); ppp is failing; rrr is saved. Remove all three.
clear_cap; abx_reset_calls
mk_backup "$GRAYJAY_BACKUP" "Guitar:::${GUITAR}" -- "AddisonCore:::${ADDISON}"
NOW=$(( T0 + 2 * DAY )); age_backup 1
run_job; rc=$?
is "removing videos is silent" "$(titles)" ""
is "...and the run succeeds" "$rc" "0"
is "a FAILING video removed from the playlist stops being tracked" "$(rec ppppppppppp .status)" "removed"
is "a video removed MID-DOWNLOAD stops being tracked too" "$(rec qqqqqqqqqqq .status)" "removed"
is "a SAVED video removed is left alone" "$(rec rrrrrrrrrrr .status)" "archived"
hasnt "...nothing removed is retried" "$(calls)" "extract"
hasnt "...or even looked up" "$(jq -r '.calls[] | join(" ")' "$FAKE")" "manage shell"
is "...and nothing is deleted in ArchiveBox (the copy and its tag stay)" \
   "$(abx ".snapshots[\"$(yt rrrrrrrrrrr)\"].tags | join(\",\")")" "Guitar"
has "...the journal counts them" "$(cat "${TMP}/out")" "2 removed"
clear_cap
NOW=$(( T0 + 9 * DAY )); age_backup 1
run_job
is "a removed failing video is never Abandoned" "$(titles)" ""

echo "added back: a fresh start"
clear_cap; abx_reset_calls
# Its last retry (queued by the fake) failed again while it was out of the playlist.
abx_snap "$(yt ppppppppppp)" sealed "Keeps Failing - YouTube" "" failed "403 Forbidden"
mk_backup "$GRAYJAY_BACKUP" "Guitar:::${GUITAR}" "$(yt ppppppppppp)" -- "AddisonCore:::${ADDISON}"
NOW=$(( T0 + 10 * DAY )); age_backup 1
run_job
is "re-adding a removed failing video starts a NEW 7-day clock" \
   "$(rec ppppppppppp '.first_failed_at | floor')" "$(( T0 + 10 * DAY ))"
has "...retried at once on its existing snapshot" "$(calls)" "extract --plugins ytdlp"
is "...first failure after re-adding: Dropped again" "$(titles)" "Dropped: 1 Video"
has "...the journal says it came back" "$(cat "${TMP}/out")" "1 added back"
clear_cap
abx_snap "$(yt ppppppppppp)" sealed "Keeps Failing - YouTube" "" succeeded "x" "Keeps_Failing.mp4"
NOW=$(( T0 + 11 * DAY )); age_backup 1
run_job
is "...and if it then saves, you are told: it had failed before" "$(titles)" "Archived: Keeps Failing"

echo "added back after it saved while out"
fresh
mk_backup "$GRAYJAY_BACKUP" "Guitar:::${GUITAR}" "$(yt uuuuuuuuuuu)" -- "AddisonCore:::${ADDISON}"
NOW=$T0; age_backup 1
run_job
abx_snap "$(yt uuuuuuuuuuu)" sealed "Late Bloomer - YouTube" "" failed "403 Forbidden"
NOW=$(( T0 + DAY )); age_backup 1; run_job
mk_backup "$GRAYJAY_BACKUP" "Guitar:::${GUITAR}" -- "AddisonCore:::${ADDISON}"
NOW=$(( T0 + 2 * DAY )); age_backup 1; run_job
# While out of the playlist, the retry already queued finished and saved it.
abx_snap "$(yt uuuuuuuuuuu)" sealed "Late Bloomer - YouTube" "" succeeded "x" "Late_Bloomer.mp4"
mk_backup "$GRAYJAY_BACKUP" "Guitar:::${GUITAR}" "$(yt uuuuuuuuuuu)" -- "AddisonCore:::${ADDISON}"
NOW=$(( T0 + 3 * DAY )); age_backup 1; clear_cap
run_job
is "re-added and found already saved: still told, because it had failed before" "$(titles)" "Archived: Late Bloomer"

echo "re-added after giving up"
fresh
mk_backup "$GRAYJAY_BACKUP" "Guitar:::${GUITAR}" "$(yt sssssssssss)" -- "AddisonCore:::${ADDISON}"
NOW=$T0; age_backup 1
run_job
abx_snap "$(yt sssssssssss)" sealed "Age Gated - YouTube" "" failed "Sign in to confirm your age"
for d in 1 3 9; do
    abx_snap "$(yt sssssssssss)" sealed "Age Gated - YouTube" "" failed "Sign in to confirm your age"
    NOW=$(( T0 + d * DAY )); age_backup 1; run_job
done
is "setup: given up after 7 days" "$(rec sssssssssss .status)" "abandoned"
clear_cap; abx_reset_calls
NOW=$(( T0 + 10 * DAY )); age_backup 1
run_job
is "a given-up video STILL in the playlist stays given up, silently" "$(rec sssssssssss .status)" "abandoned"
is "...no message" "$(titles)" ""
hasnt "...no retry" "$(calls)" "extract"
mk_backup "$GRAYJAY_BACKUP" "Guitar:::${GUITAR}" -- "AddisonCore:::${ADDISON}"
NOW=$(( T0 + 11 * DAY )); age_backup 1
run_job
is "taking it out marks it removed" "$(rec sssssssssss .status)" "removed"
abx_snap "$(yt sssssssssss)" sealed "Age Gated - YouTube" "" failed "Sign in to confirm your age"
mk_backup "$GRAYJAY_BACKUP" "Guitar:::${GUITAR}" "$(yt sssssssssss)" -- "AddisonCore:::${ADDISON}"
NOW=$(( T0 + 12 * DAY )); age_backup 1; clear_cap
run_job
is "putting it back gives it a fresh start: Dropped again" "$(titles)" "Dropped: 1 Video"

echo "what does NOT count as removed"
fresh
mk_backup "$GRAYJAY_BACKUP" "Guitar:::${GUITAR}" "$(yt ttttttttttt)" -- "AddisonCore:::${ADDISON}"
NOW=$T0; age_backup 1
run_job
abx_snap "$(yt ttttttttttt)" sealed "Missing Parent - YouTube" "" failed "403 Forbidden"
NOW=$(( T0 + DAY )); age_backup 1
run_job
mk_backup "$GRAYJAY_BACKUP" "AddisonCore:::${ADDISON}"
NOW=$(( T0 + 2 * DAY )); age_backup 1
run_job
is "a video whose whole PLAYLIST went missing is not 'removed'" "$(rec ttttttttttt .status)" "pending"
printf 'garbage' > "$GRAYJAY_BACKUP"; printf 'garbage' > "${GRAYJAY_BACKUP}.old"
NOW=$(( T0 + 3 * DAY )); age_backup 1
run_job
isnt_removed="$(rec ttttttttttt .status)"
[[ "$isnt_removed" != "removed" ]] && ok "an UNREADABLE backup removes nothing" || bad "an UNREADABLE backup removes nothing" "not removed" "$isnt_removed"

# ===================================================================== ArchiveBox
echo "ArchiveBox unreachable"
fresh
standard_backup
abx_flag down
run_job; rc=$?
is "ArchiveBox down: ArchiveBox: Unreachable" "$(titles)" "ArchiveBox: Unreachable"
is "...on its stable id" "$(ids)" "grayjay-archivebox"
has "...counting what was not handed over" "$(bodies)" "4 new videos were not handed over"
has "...with docker's own words, escaped" "$(bodies)" "container archivebox is not running"
is "...and the run FAILS" "$( ((rc != 0)) && echo yes)" "yes"
is "...and nothing is recorded, so tomorrow tries again" "$(find "$GRAYJAY_STATE" -name '*.json' 2>/dev/null | wc -l)" "0"
abx_unflag down; clear_cap
run_job; rc=$?
is "back up: the same videos are handed over, one add per tag set" "$(calls | grep -c ' add ')" "3"
is "...and the run succeeds" "$rc" "0"
# The recovery rule (2026-10-31): a fault that heals on its own says so, in place.
is "...and the fault becomes ArchiveBox: Reachable" "$(titles)" "ArchiveBox: Reachable"
is "...on the SAME id, so it replaces the fault on the phone" "$(ids)" "grayjay-archivebox"
clear_cap
run_job
is "a second healthy run says nothing more" "$(titles)" ""

echo "the backup recovers"
fresh
standard_backup
age_backup 8
run_job
is "a stale backup: Backup: 8 Days Old" "$(titles)" "Backup: 8 Days Old"
age_backup 1; clear_cap
run_job
is "a fresh one arrives: Backup: Current" "$(titles)" "Backup: Current"
is "...on the backup's id" "$(ids)" "grayjay-backup"

fresh
standard_backup
abx_flag add_fails
run_job; rc=$?
is "add refused: ArchiveBox: Unreachable as well" "$(titles)" "ArchiveBox: Unreachable"
is "...the run fails" "$( ((rc != 0)) && echo yes)" "yes"
is "...and no record is written for a video that did not go over" "$(find "$GRAYJAY_STATE/videos" -name '*.json' 2>/dev/null | wc -l)" "0"

# ===================================================================== the envelope
echo "envelope"
fresh
standard_backup
age_backup 8
UNDELIVERED=1 run_job; rc=$?
is "an alert that could not be delivered FAILS the unit" "$( ((rc != 0)) && echo yes)" "yes"
has "...and says so in the journal" "$(cat "${TMP}/err")" "not delivered"

fresh
standard_backup
mkdir -p "$GRAYJAY_STATE"
exec 8>"${GRAYJAY_STATE}/.lock"; flock -n 8
run_job; rc=$?
exec 8>&-
is "a run that finds the lock held exits 0" "$rc" "0"
hasnt "...and does nothing" "$(calls)" " add "

fresh
standard_backup
mkdir -p "$GRAYJAY_STATE/videos"
printf 'not json' > "$GRAYJAY_STATE/videos/aaaaaaaaaaa.json"
run_job; rc=$?
is "an unreadable record FAILS the run rather than re-handing the video" "$( ((rc != 0)) && echo yes)" "yes"
hasnt "...nothing is handed over" "$(calls)" " add "
has "...the crash is in the journal" "$(cat "${TMP}/err")" "crashed"

# ===================================================================== the contract
echo "contract"
err() { CONTRACT_ERR+="$*"$'\n'; }
CONTRACT_ERR=""
# shellcheck source=../../systemd/contract.sh
source "${REPO}/systemd/contract.sh"
intake_contract "${SELF_DIR}/.." grayjay
is "every title passes systemd/contract.sh" "$CONTRACT_ERR" ""
# The gate must be READING this tree, or the line above proves nothing.
mkdir -p "${TMP}/gate/scripts"
cp "${SCRIPT_DIR}/grayjay.lib.sh" "${TMP}/gate/scripts/"
printf 'notify_fault "Backup Stopped" "x"\n' > "${TMP}/gate/scripts/bad.sh"
CONTRACT_ERR=""
intake_contract "${TMP}/gate" grayjay
has "...and the gate refuses a hand-built title in this layout" "$CONTRACT_ERR" "builds a notification title by hand"
is "titles stay inside the 40-char cap" \
   "$(source "${REPO}/ntfy/kinds.sh"; t="$(title_count Archived 1 Video "A Very Long YouTube Title That Goes On And On Forever")"; echo "${#t}")" "40"

echo "hygiene"
real="$(source "${SCRIPT_DIR}/grayjay.lib.sh"; printf '%s\n' "${PLAYLISTS[@]}")"
is "production follows exactly four playlists" "$(wc -l <<<"$real")" "4"
for t in GuitarCore AddisonCore HowFarAwayIsIt AbsolutelyUnderstandGuitar; do
    has "...including $t" "$real" "=$t"
done
is "...each by a full UUID" "$(grep -cE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}=[A-Za-z]+$' <<<"$real")" "4"
for s in archive.sh lib.sh archive.py; do
    [[ -x "${SCRIPT_DIR}/grayjay.${s}" ]] && ok "grayjay.${s} is executable" || bad "grayjay.${s} is executable" "+x" "not executable"
done
[[ -d "${SELF_DIR}/../state" ]] && git -C "$REPO" ls-files --error-unmatch grayjay/state/.gitkeep >/dev/null 2>&1 \
    && ok "the state dir is tracked (ReadWritePaths= fails 226/NAMESPACE on a missing path)" \
    || bad "the state dir is tracked (ReadWritePaths= fails 226/NAMESPACE on a missing path)" "grayjay/state/.gitkeep tracked" "missing or untracked"
hasnt "no script reaches the model API" "$(cat "$SCRIPT_DIR"/*)" "api.anthropic.com"
hasnt "no unit loads a secret" "$(grep -h '^EnvironmentFile' "$SELF_DIR"/../systemd/* )" "EnvironmentFile"
hasnt "the request is never interpolated into the helper's code" "$(cat "${SCRIPT_DIR}/grayjay.abx.py")" "GJ_REQ}"
has "the helper reads the request from the environment" "$(cat "${SCRIPT_DIR}/grayjay.abx.py")" 'os.environ.get("GJ_REQ")'

echo
echo "${PASS} passed, ${FAIL} failed"
(( FAIL == 0 ))
