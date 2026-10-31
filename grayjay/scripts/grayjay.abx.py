# Runs INSIDE the archivebox container, through Django's shell:
#   docker exec -e GJ_REQ -u archivebox -w /data archivebox \
#       archivebox manage shell -c "<this file>"
#
# It answers one question per video — does a snapshot exist, and what did its ytdlp
# result say — and, when asked, makes sure the snapshot carries every playlist tag.
# It decides NOTHING: the verdict (archived, still going, failed and why) is made on the
# host in grayjay.archive.py, where the suite can reach it. Keeping this side to lookups
# is what lets a fake ArchiveBox stand in for it offline.
#
# WHY THE TAGS ARE SET HERE. `archivebox add --tag` cannot tag a snapshot that already
# exists: with ONLY_NEW the crawl `continue`s past a known URL before tags are applied
# (crawls/models.py, 0.9.70), and the CLI has no tagging verb. So a video in BOTH
# playlists, or one archived by hand before this job existed, would never get its
# second tag. Tag.get_or_create_by_name + Snapshot.add_tag_ids are the two calls the
# crawl itself uses to tag a new snapshot, so this is the same write by the same path.
#
# The request rides in an ENVIRONMENT variable, never in this program's text, so a URL
# is data and can never become code. The answer comes back on one marker line, because
# the shell prints its own banner to stdout first.
import json
import os

from archivebox.core.models import Snapshot, Tag

req = json.loads(os.environ.get("GJ_REQ") or "{}")
apply_tags = bool(req.get("apply_tags"))
answer = {}

for item in req.get("items", []):
    key = item["key"]
    snap = Snapshot.objects.filter(url=item["url"]).order_by("created_at").first()
    for alt in item.get("alt", []):
        if snap is not None:
            break
        snap = Snapshot.objects.filter(url__contains=alt).order_by("created_at").first()
    if snap is None:
        answer[key] = {"exists": False}
        continue

    have = set(snap.tags.values_list("name", flat=True))
    wanted = [t for t in item.get("tags", []) if t and t not in have]
    if apply_tags and wanted:
        snap.add_tag_ids([Tag.get_or_create_by_name(t)[0].pk for t in wanted])
        have.update(wanted)

    res = snap.archiveresult_set.filter(plugin="ytdlp").order_by("-modified_at").first()
    ytdlp = None
    if res is not None:
        ytdlp = {
            "status": res.status,
            "output": (res.output_str or "")[:2000],
            "notes": (res.notes or "")[-2000:],
            "files": sorted(res.output_files or []),
        }
    answer[key] = {
        "exists": True,
        "id": str(snap.id),
        "status": snap.status,
        "title": snap.title or "",
        "tags": sorted(have),
        "ytdlp": ytdlp,
    }

print("GJ_RESULT=" + json.dumps(answer))
