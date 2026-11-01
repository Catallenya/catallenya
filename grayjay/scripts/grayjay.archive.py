#!/usr/bin/env python3
"""The decision half of the grayjay job. Called by grayjay.archive.sh, which owns
every notification; this file owns everything else and reports what happened as ONE
JSON object on stdout. Logs go to stderr, which the journal keeps.

    python3 -I grayjay.archive.py            # reads its settings from the environment

Exit 0 when the job did its work (whatever it found), 2 when it could not — the backup
unreadable or ArchiveBox unreachable — and anything else is a crash. The report is
printed in both of the first two cases so the wrapper can say WHICH.

STATE IS THE FILESYSTEM (docs/intake-playbook.md). One record per video in
state/videos/<key>.json, holding that video's verdict and nothing else: no ledger, no
checksum of the last backup, no list of what was sent. A video whose record exists has
been dealt with; the record says how.

    pending    handed to ArchiveBox, result not in yet
    archived   a complete video file is in its snapshot             (silent unless it had failed)
    adopted    the snapshot already existed WITH the video          (silent)
    failed     the last attempt failed; retried daily, quietly
    abandoned  failing 7 days from the FIRST failure                (fault sent)
    removed    taken out of every playlist while unfinished; no longer tracked (silent)

WHAT THE PHONE HEARS (owner, 2026-10-31): only problems. A video that saves is silent,
however many arrive; the one exception is a video you were TOLD had failed (Dropped or
Abandoned) that later saves after all, which sends `Archived: <title>` to close the loop.

There is deliberately NO "backup unchanged, skip" shortcut, although the brief suggested
one. Parsing the backup costs ~20 ms, and a remembered checksum is exactly the kind of
state that can say "done" when a hand-over failed — every run diffs the playlists
against the records instead, which is idempotent and needs nothing remembered.
"""
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import time
import zipfile
from pathlib import Path

# --------------------------------------------------------------------------- settings
BACKUP = Path(os.environ.get("GRAYJAY_BACKUP", ""))
STATE = Path(os.environ.get("GRAYJAY_STATE", ""))
DOCKER = os.environ.get("GRAYJAY_DOCKER", "docker")
NOW = float(os.environ.get("GRAYJAY_NOW") or time.time())
PLAYLISTS = [p.split("=", 1) for p in os.environ.get("GRAYJAY_PLAYLISTS", "").split()]
HELPER = Path(__file__).with_name("grayjay.abx.py")

DAY = 86400
GIVE_UP = 7 * DAY      # from the FIRST failure, never the last attempt (playbook)
NO_SNAPSHOT_GRACE = DAY  # `add --bg` returns before the snapshot exists
STALE_AFTER = 7 * DAY

HEADER = bytes.fromhex("11223344474a0100")   # magic, "GJ", version 1, flags 0 (unencrypted)
EOCD = b"PK\x05\x06"

# Every extension yt-dlp can leave a finished download in. Taken from the ytdlp plugin's
# own MEDIA_EXTENSIONS preference list (abx_plugins/plugins/ytdlp/config.json).
MEDIA = {
    ".mp4", ".webm", ".m4v", ".ogv", ".mp3", ".m4a", ".aac", ".opus", ".ogg", ".wav",
    ".flac", ".mkv", ".mov", ".avi", ".flv", ".wmv", ".mpg", ".mpeg", ".ts", ".3gp",
}
# yt-dlp downloads video and audio separately as `Title.f299.mp4` + `Title.f251.webm`,
# then merges them. A timeout between the two leaves a finished, video-only `.fNNN.`
# file, and the plugin counts ANY media file as success — measured in its source, not
# assumed: `except TimeoutExpired: output = selected_output(...); if output: return True`.
FORMAT_PART = re.compile(r"\.f\d+\.[A-Za-z0-9]+$")


def log(msg):
    print(msg, file=sys.stderr)


# ----------------------------------------------------------------------- the backup
def open_backup(path):
    """Return the playlists out of one backup file, or raise ValueError.

    Grayjay overwrites the file in place WITHOUT truncating it, so a backup smaller than
    the last one keeps the old one's tail — 232 junk bytes after the zip on 19 Oct, which
    zipfile refuses. The real archive ends at an end-of-central-directory record plus its
    22 bytes (and comment); the junk tail carries the OLD archive's EOCD. So try each
    EOCD in order and keep the first cut that opens and reads.
    """
    data = path.read_bytes()
    if data[:8] != HEADER:
        raise ValueError("not a Grayjay backup (header %s)" % data[:8].hex())
    body = data[8:]
    start = 0
    while True:
        at = body.find(EOCD, start)
        if at < 0:
            raise ValueError("no readable zip inside")
        start = at + 1
        if at + 22 > len(body):
            continue
        comment = int.from_bytes(body[at + 20:at + 22], "little")
        try:
            zf = zipfile.ZipFile(io.BytesIO(body[:at + 22 + comment]))
            raw = zf.read("stores/Playlists")
            entries = json.loads(raw)
        except Exception:  # a false EOCD inside compressed data, or a cut too early
            continue
        return parse_playlists(entries)


def parse_playlists(entries):
    """stores/Playlists is a JSON list of strings: "<name>:::<uuid>\\n<url>\\n<url>…"."""
    out = {}
    if not isinstance(entries, list):
        raise ValueError("stores/Playlists is not a list")
    for s in entries:
        if not isinstance(s, str):
            continue
        head, *urls = s.split("\n")
        name, sep, uuid = head.rpartition(":::")
        if not sep:
            continue
        out[uuid.strip()] = (name, [u.strip() for u in urls if u.strip()])
    return out


def read_backup():
    """(playlists or None, which file, newest mtime or None).

    The newest mtime is taken over BOTH files whether or not they parse: staleness is a
    question about the phone, not about whether we could read what it sent.
    """
    candidates = [BACKUP, BACKUP.with_name(BACKUP.name + ".old")]
    mtimes = [p.stat().st_mtime for p in candidates if p.is_file()]
    newest = max(mtimes) if mtimes else None
    for label, path in zip(("main", "old"), candidates):
        if not path.is_file():
            continue
        try:
            return open_backup(path), label, newest
        except (OSError, ValueError) as e:
            log("backup %s unreadable: %s" % (path.name, e))
    return None, None, newest


# ------------------------------------------------------------------------- the URLs
YT_ID = re.compile(r"^[A-Za-z0-9_-]{11}$")
YT_HOSTS = {"youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"}


def canonical(url):
    """(key, url ArchiveBox gets, substrings that find an older snapshot of it).

    LOAD-BEARING, not tidying. Grayjay stores whatever was shared: `youtu.be/<id>?si=…`
    tracking links and, in the live backup, one `watch?v=<id>&list=RD<id>&start_radio=1`.
    ArchiveBox runs yt-dlp with `--yes-playlist`, so that last one handed over as-is
    would archive an entire endless radio mix. Every YouTube form becomes the bare
    `https://www.youtube.com/watch?v=<id>`, which is also the form every existing
    YouTube snapshot in this ArchiveBox uses — so ONLY_NEW's exact-URL dedup works.
    """
    from urllib.parse import urlsplit, parse_qs
    u = url.strip()
    try:
        parts = urlsplit(u)
    except ValueError:
        parts = None
    vid = None
    if parts and parts.hostname:
        host = parts.hostname.lower()
        path = parts.path
        if host == "youtu.be":
            vid = path.strip("/").split("/")[0]
        elif host in YT_HOSTS:
            if path == "/watch":
                vid = (parse_qs(parts.query).get("v") or [""])[0]
            elif path.startswith(("/shorts/", "/live/", "/embed/")):
                vid = path.split("/")[2] if len(path.split("/")) > 2 else ""
    if vid and YT_ID.match(vid):
        return (vid, "https://www.youtube.com/watch?v=" + vid,
                ["watch?v=" + vid, "youtu.be/" + vid, "shorts/" + vid])
    # Grayjay plays other platforms too. Those are handed over exactly as stored, keyed
    # by a hash because their URL is the only identity they have.
    return ("u-" + hashlib.sha256(u.encode()).hexdigest()[:16], u, [])


# ------------------------------------------------------------------------ the records
def videos_dir():
    return STATE / "videos"


def load_records():
    out = {}
    d = videos_dir()
    if not d.is_dir():
        return out
    for f in d.glob("*.json"):
        try:
            rec = json.loads(f.read_text())
            out[rec["key"]] = rec
        except (OSError, ValueError, KeyError) as e:
            # A record we cannot read is NOT treated as absent: that would hand the video
            # over a second time. Fail the run instead, so a human looks.
            raise SystemExit("unreadable record %s: %s" % (f.name, e))
    return out


def save(rec):
    d = videos_dir()
    d.mkdir(parents=True, exist_ok=True)
    tmp = d / (rec["key"] + ".json.tmp")
    tmp.write_text(json.dumps(rec, indent=1, sort_keys=True) + "\n")
    tmp.replace(d / (rec["key"] + ".json"))


# --------------------------------------------------------------------- ArchiveBox
class Unreachable(Exception):
    pass


def docker(args, env=None, timeout=300):
    try:
        p = subprocess.run([DOCKER, *args], capture_output=True, text=True,
                           timeout=timeout, env=env)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise Unreachable(str(e)[:200])
    if p.returncode != 0:
        tail = (p.stderr or p.stdout).strip().splitlines()[-1:] or ["exit %d" % p.returncode]
        raise Unreachable(tail[0][:200])
    return p.stdout


ABX = ["exec", "-u", "archivebox", "-w", "/data", "archivebox", "archivebox"]


def abx_query(items):
    env = dict(os.environ, GJ_REQ=json.dumps({"apply_tags": True, "items": items}))
    out = docker(["exec", "-e", "GJ_REQ", "-u", "archivebox", "-w", "/data",
                  "archivebox", "archivebox", "manage", "shell", "-c",
                  HELPER.read_text()], env=env)
    for line in out.splitlines():
        if line.startswith("GJ_RESULT="):
            return json.loads(line[len("GJ_RESULT="):])
    raise Unreachable("ArchiveBox shell gave no answer")


def abx_add(tags, urls):
    # --bg: queue and return. Downloads take minutes to hours and are judged on a later
    # run, never waited for here. title,ytdlp only: the video and its sidecars, plus the
    # page title (ytdlp alone leaves the snapshot's title null).
    docker([*ABX, "add", "--bg", "--tag", ",".join(tags), "--plugins", "title,ytdlp",
            *urls])


def abx_retry(snapshot_ids):
    # Re-queue ONLY the ytdlp plugin on the existing snapshot. `add` cannot retry:
    # ONLY_NEW skips the URL, and --overwrite would make a second snapshot of it.
    docker([*ABX, "extract", "--plugins", "ytdlp", "--no-wait", *snapshot_ids])


# ------------------------------------------------------------------------ verdicts
def compact(seconds):
    s = int(seconds)
    h, m = divmod(s // 60, 60)
    if s < 60:
        return "%ds" % s
    if h and m:
        return "%dh %dm" % (h, m)
    return "%dh" % h if h else "%dm" % m


def complete_media(files):
    for f in files:
        name = f.rsplit("/", 1)[-1]
        ext = os.path.splitext(name)[1].lower()
        if ext in MEDIA and not FORMAT_PART.search(name):
            return True
    return False


def reason(ytdlp):
    """One line saying why there is no video. No full stop: it is a DETAIL line."""
    text = (ytdlp.get("output") or "") + "\n" + (ytdlp.get("notes") or "")
    m = re.search(r"[Tt]imed out after (\d+) seconds", text)
    if m:
        return "Timed out after " + compact(m.group(1))
    files = ytdlp.get("files") or []
    if any(f.endswith((".part", ".ytdl")) or FORMAT_PART.search(f) for f in files):
        return "Download did not finish"
    errors = [l.strip() for l in text.splitlines() if l.strip().startswith("ERROR:")]
    if errors:
        msg = re.sub(r"^ERROR:\s*(\[[^\]]+\]\s*)?([A-Za-z0-9_-]{11}:\s*)?", "", errors[-1])
        # First sentence only. yt-dlp follows the cause with advice and two wiki URLs
        # ("Sign in to confirm your age. Use --cookies-from-browser … See https://…"),
        # which is a paragraph on a lock screen and says nothing the cause does not.
        msg = msg.split(". ", 1)[0]
        return msg.rstrip(".")[:140] or "yt-dlp reported an error"
    # The plugin's own one-liners: "404 Not Found", "403 Forbidden", "No media found",
    # "Unable to extract media info", "yt-dlp terminated before producing media".
    first = (ytdlp.get("output") or "").strip().splitlines()
    if first and not first[0].startswith("yt-dlp error:"):
        return first[0].rstrip(".")[:140]
    return "No video file was saved"


def verdict(f):
    """(state, why) for one video's facts from ArchiveBox."""
    if not f.get("exists"):
        return "absent", None
    y = f.get("ytdlp")
    if f.get("status") in ("queued", "started"):
        return "pending", None
    if y and y.get("status") in ("queued", "started", "backoff", "paused"):
        return "pending", None
    if y is None:
        return "failed", "No download was attempted"
    # THE FILES DECIDE, IN BOTH DIRECTIONS. A merged, non-partial media file means the
    # video is archived whatever the status says: yt-dlp gives a download its final name
    # only once it is complete (`.part` until then, `.fNNN.` before the merge). Measured
    # both ways on the first backfill, 2026-10-20: EC2vwX2T0jA read "succeeded" holding
    # only an audio stream and a .part, and WJO7GWaeM8M read "failed" with no message
    # and no end time while holding a complete 3632 s merged .webm. Trusting "failed"
    # there would have sent a false Dropped and re-downloaded an hour-long mix.
    if complete_media(y.get("files") or []):
        return "archived", None
    return "failed", reason(y)


def backfill(rec, f, to_retry, report):
    """An existing snapshot WITHOUT the video is not adopted: it is downloaded.

    Found live on 2026-11-01: two playlist videos had been saved as 2025 bookmarks, which
    kept the web page and no video, and adoption counted them done. Now a snapshot is
    adopted only if it already holds a complete video. Otherwise ytdlp is run on that same
    snapshot (no second snapshot, the tags stay), silently, and the record becomes an
    ordinary pending one: it is announced only if that download then fails, like any other.
    Records adopted before this rule are re-checked the same way. Returns True when the
    record was taken over.
    """
    state, _ = verdict(f)
    if state in ("archived", "absent"):
        return False
    rec["status"] = "pending"
    rec["first_failed_at"] = None
    rec["handed_over_at"] = NOW
    rec["backfilled_at"] = NOW
    if state == "failed":
        to_retry.append(rec)   # the hand-over loop saves it and counts it
    else:
        save(rec)              # a download is already running on it; just wait
    report["backfilled"] += 1
    return True


def clean_title(t, fallback):
    t = (t or "").strip()
    t = re.sub(r"\s+-\s+YouTube$", "", t)
    return t or fallback


# ---------------------------------------------------------------------------- run
def main():
    report = {"backup": {}, "missing": [], "archivebox": "ok", "archivebox_error": "",
              "archived": [], "dropped": [], "abandoned": [], "handed": 0,
              "retried": 0, "adopted": 0, "backfilled": 0, "pending": 0, "removed": 0,
              "readded": 0}

    playlists, used, newest = read_backup()
    report["backup"] = {
        "state": "ok" if playlists is not None else "unreadable",
        "used": used,
        "newest": newest,
        "stale": newest is None or NOW - newest > STALE_AFTER,
        "age_days": int((NOW - newest) // DAY) if newest else None,
    }
    if used == "old":
        log("main backup unreadable; used GrayjayBackup.ezip.old")

    wanted = {}   # key -> {"url", "alt", "tags"}
    if playlists is not None:
        for uuid, tag in PLAYLISTS:
            if uuid not in playlists:
                report["missing"].append({"tag": tag, "uuid": uuid})
                continue
            for url in playlists[uuid][1]:
                key, canon, alt = canonical(url)
                w = wanted.setdefault(key, {"url": canon, "alt": alt, "tags": []})
                if tag not in w["tags"]:
                    w["tags"].append(tag)

    records = load_records()

    # REMOVAL (owner, 2026-10-31). A video taken out of every allow-listed playlist while
    # it is still unfinished (pending, failed or abandoned) stops being tracked, silently:
    # no more retries, no Abandoned, and nothing in ArchiveBox is touched, so a download
    # already running finishes on its own and keeps its copy. Finished videos (archived,
    # adopted) are left exactly as they are; removing a video never deletes the copy or
    # its tag. Two guards, because a wrong "removed" silently stops real work: only a
    # READABLE backup can say a video is gone, and a video whose playlist is itself
    # Missing (deleted and recreated, new UUID) is not gone, its playlist is.
    if playlists is not None:
        missing_tags = {m["tag"] for m in report["missing"]}
        for k, rec in records.items():
            if k in wanted or rec["status"] not in ("pending", "failed", "abandoned"):
                continue
            if any(t in missing_tags for t in rec.get("tags", [])):
                continue
            rec["status"] = "removed"
            rec["removed_at"] = NOW
            save(rec)
            report["removed"] += 1

    live = {k for k, r in records.items() if r["status"] in ("pending", "failed")}
    keys = sorted(set(wanted) | live)
    items = []
    for k in keys:
        rec = records.get(k, {})
        tags = sorted(set(wanted.get(k, {}).get("tags", [])) | set(rec.get("tags", [])))
        src = wanted.get(k) or {"url": rec["url"], "alt": rec.get("alt", [])}
        items.append({"key": k, "url": src["url"], "alt": src["alt"], "tags": tags})

    # Whether ArchiveBox was actually asked this run. "ok" is the report's DEFAULT, so on
    # its own it cannot tell "answered" from "never asked"; the shell closes an open
    # ArchiveBox fault only on a run that really reached it.
    report["archivebox_asked"] = bool(items)
    try:
        facts = abx_query(items) if items else {}
    except Unreachable as e:
        report["archivebox"] = "unreachable"
        report["archivebox_error"] = str(e)
        report["not_handed"] = sum(1 for k in wanted if k not in records)
        print(json.dumps(report))
        return 2

    to_add = {}      # tuple(tags) -> [record]
    to_retry = []    # records with a snapshot to re-run ytdlp on
    for it in items:
        k = it["key"]
        f = facts.get(k, {"exists": False})
        rec = records.get(k)
        if rec is None:
            if f.get("exists"):
                # Archived before this job saw it — by hand, or by the 2025 bookmarks.
                # Tagged (above) and never announced. Adopted as it is only when it
                # already holds the video; otherwise see backfill() below.
                rec = {"key": k, "url": it["url"], "alt": it["alt"], "tags": it["tags"],
                       "status": "adopted", "snapshot_id": f.get("id"),
                       "title": clean_title(f.get("title"), it["url"]),
                       "first_seen_at": NOW}
                if not backfill(rec, f, to_retry, report):
                    save(rec)
                    report["adopted"] += 1
            else:
                rec = {"key": k, "url": it["url"], "alt": it["alt"], "tags": it["tags"],
                       "status": "new", "first_seen_at": NOW, "first_failed_at": None}
                to_add.setdefault(tuple(it["tags"]), []).append(rec)
            continue

        rec["tags"] = it["tags"]
        if rec["status"] == "removed":
            # ADDED BACK after a removal: a fresh start (owner, 2026-10-31). A new 7-day
            # clock, so it can be Dropped and Abandoned again; `had_failed` remembers that
            # you were once told it failed, so a later success still closes the loop.
            rec["had_failed"] = bool(rec.get("had_failed") or rec.get("first_failed_at"))
            rec["first_failed_at"] = None
            rec.pop("removed_at", None)
            rec["status"] = "pending"
            rec["handed_over_at"] = NOW
            report["readded"] += 1
            if not f.get("exists"):
                rec["status"] = "failed"   # routed through the hand-over below
                save(rec)
                to_add.setdefault(tuple(rec["tags"]), []).append(rec)
                continue
        if rec["status"] == "adopted" and f.get("exists"):
            if backfill(rec, f, to_retry, report):
                continue   # judged tomorrow, like any fresh hand-over
        if rec["status"] not in ("pending", "failed"):
            save(rec)
            continue
        if f.get("exists"):
            rec["snapshot_id"] = f.get("id")
            rec["title"] = clean_title(f.get("title"), rec.get("title") or rec["url"])
        state, why = verdict(f)
        if state == "absent" and NOW - rec.get("handed_over_at", NOW) < NO_SNAPSHOT_GRACE:
            state = "pending"
        elif state == "absent":
            state, why = "failed", "ArchiveBox never created a snapshot"

        if state == "pending":
            report["pending"] += 1
            save(rec)
        elif state == "archived":
            rec["status"] = "archived"
            rec["archived_at"] = NOW
            save(rec)
            report["archived"].append({
                "title": rec["title"], "tags": rec["tags"],
                # Only these are announced: you were told this video had failed.
                "recovered": bool(rec.get("first_failed_at") or rec.get("had_failed")),
            })
        else:
            rec["last_reason"] = why
            title = rec.get("title") or rec["url"]
            if not rec.get("first_failed_at"):
                rec["first_failed_at"] = NOW
                report["dropped"].append({"title": title, "reason": why})
            elif NOW - rec["first_failed_at"] >= GIVE_UP:
                rec["status"] = "abandoned"
                save(rec)
                report["abandoned"].append({"title": title, "reason": why})
                continue
            rec["status"] = "failed"
            save(rec)
            if f.get("exists"):
                to_retry.append(rec)
            else:
                to_add.setdefault(tuple(rec["tags"]), []).append(rec)

    sent = set()
    try:
        for tags, recs in sorted(to_add.items()):
            abx_add(list(tags), [r["url"] for r in recs])
            for r in recs:
                sent.add(r["key"])
                r["handed_over_at"] = NOW
                r["status"] = "pending"
                save(r)
                if r.get("first_failed_at"):
                    report["retried"] += 1
                else:
                    report["handed"] += 1
        if to_retry:
            abx_retry([r["snapshot_id"] for r in to_retry])
            for r in to_retry:
                r["status"] = "pending"
                save(r)
            report["retried"] += sum(1 for r in to_retry if r.get("backfilled_at") != NOW)
    except Unreachable as e:
        # Nothing new is recorded for what did not go over, so tomorrow tries again.
        report["archivebox"] = "unreachable"
        report["archivebox_error"] = str(e)
        report["not_handed"] = sum(1 for v in to_add.values() for r in v
                                   if r["key"] not in sent)
        print(json.dumps(report))
        return 2

    print(json.dumps(report))
    return 2 if playlists is None else 0


if __name__ == "__main__":
    sys.exit(main())
