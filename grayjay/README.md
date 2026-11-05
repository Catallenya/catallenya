# grayjay

Keeps a copy of every video in the Grayjay playlists and channels you choose, so a
video that disappears from YouTube is still watchable.

**You choose on the phone, never in this repo:**

- **A playlist** is followed while its name starts with **📦**, e.g. `📦 Guitar`.
- **A channel** is followed while it is in the Grayjay subscription group **Archive**.
  Every video on its Videos tab is kept, old and new; Shorts and live streams are not.

Within a day or two each video is in ArchiveBox, tagged with the playlist's or channel's
name, letters and digits only: `📦 How Far Away Is It` → `HowFarAwayIsIt`,
`K's Archives` → `KsArchives`. Nothing tells you so: the `grayjay` topic is **silent
unless something fails** (see Decisions below).

## How it works

```
phone: Grayjay auto-backup (every ~2 days, only while the app runs)
   → master/config/GrayjayBackup.ezip, over Syncthing (Grayjay's .ezip.old spare is never read)

grayjay.archive.timer, daily 07:55 SGT
   → read the 📦 playlists and the Archive group's channels out of the backup
   → list each channel's Videos tab (ArchiveBox's own yt-dlp, --flat-playlist)
   → each video never seen before → archivebox add --bg --tag <Playlist> --plugins title,ytdlp
   → each video handed over earlier → did a complete video file land?
   → ntfy, problems only: Dropped / Abandoned / Backup / Channel / Unreachable,
     plus Archived for a video that had failed and was later saved
```

There is no model, no button and no drop zone. Marking the playlist, or grouping the
channel, is the whole decision, so everything sent is a receipt or a fault (`ntfy/MESSAGES.md` § 7).

## Decisions

Settled with the owner on 2026-10-31 and 2026-11-01. Each one is enforced by a case in `tests/run.sh`.

| Situation | What happens |
|---|---|
| A video saves | **Nothing is sent.** The phone hears only about problems |
| A video fails to download | `Dropped` once, silent daily retries, `Abandoned` 7 days after the FIRST failure. Two messages per video, never more |
| A video that failed later saves | `Archived: <title>`, the one piece of good news, so a failure you were told about is always closed |
| A system problem lasts days (ArchiveBox down, backup over 7 days old, a channel that cannot be listed, backup unreadable) | ONE notification that refreshes itself each morning until fixed: at most one buzz a day, never a pile |
| How often it checks | once a day, 07:55 SGT |
| A video is taken out of the playlist while unfinished (failing, given up, or still downloading) | It stops being tracked, silently. Nothing in ArchiveBox is touched: a running download finishes on its own and keeps its copy |
| A saved video is taken out of the playlist | Nothing changes. The copy and its playlist tag stay |
| A video taken out is added back | A fresh start: it is retried first, quietly, then judged like a new video on a new 7-day clock, so it can be `Dropped` and `Abandoned` again; if it saves, `Archived` (it had failed before) |
| A given-up video is still in the playlist | It stays given up, silently. To retry it, delete its record (`state/videos/<id>.json`); the next run tries again |
| A download is still running a day after it was asked for, or still waiting in line after 7 | It is stuck, so it counts as a failure (`Download stuck`): `Dropped`, retried daily, `Abandoned` like any other |
| The 📦 is taken off a playlist, the playlist is deleted, or a channel leaves the Archive group | It stops being followed: the same as taking each of its videos out. Saved copies and their tags stay |
| A video vanishes from a channel still in the group (deleted, made private) before it was saved | **Not** let go: it is a failure, so `Dropped` then `Abandoned`. That loss is exactly what an archive is for, so you are told |
| A channel cannot be listed, or the backup cannot be read | Nothing counts as "taken out"; `Channel: Unreadable` or `Backup: Unreadable` is sent instead. While ArchiveBox is down only `ArchiveBox: Unreachable` is sent: the listing runs inside it, so every channel would fail with it |
| The newest backup cannot be opened | `Backup: Unreadable` that morning, even if Grayjay's older spare (`.ezip.old`) would open: the spare only hid a broken newest file behind an ever-older list. Nothing is handed over or taken out; it tries again tomorrow |
| A followed playlist or channel is renamed | New videos get the new tag; videos already tagged keep the old one too |

## Files

| Path | What |
|---|---|
| `scripts/grayjay.lib.sh` | settings: the 📦 marker, the group name, paths, vocabulary |
| `scripts/grayjay.archive.sh` | the entry point; turns the report into notifications |
| `scripts/grayjay.archive.py` | the work: parse the backup, keep the records, judge results |
| `scripts/grayjay.abx.py` | runs inside the ArchiveBox container: look up snapshots, add tags |
| `systemd/grayjay.archive.{service,timer}` | the job (`Class=scheduled`, `Family=intake`) |
| `tests/run.sh` | the offline suite |
| `state/videos/<id>.json` | one record per video (not in git) |

## State

One record per video in `state/videos/`, and nothing else. The record's `status` is the
whole truth about that video:

| status | meaning |
|---|---|
| `pending` | handed to ArchiveBox; the download has not finished |
| `archived` | a complete video file is in its snapshot |
| `adopted` | the snapshot existed before this job saw the video AND already holds the video; tagged, never re-downloaded. A snapshot without the video (a page-only bookmark) is not adopted: ytdlp is run on it silently and it becomes `pending` (2026-11-01) |
| `failed` | the last attempt failed; retried daily without a notification |
| `abandoned` | still failing 7 days after the FIRST failure; never retried again |
| `removed` | no longer followed while unfinished; no longer tracked. Follow it again for a fresh start |

To retry an abandoned video, delete its record. To start over completely, delete
`state/`: every video whose snapshot already holds the video is adopted again, nothing
is downloaded twice.

## Things worth knowing

- **Until 2026-11-01 the playlists were a hand-kept list of UUIDs** in
  `scripts/grayjay.lib.sh`, so every new playlist meant a change to this repo. The
  marker and the group replaced it, and the `<Tag>: Missing` fault went with it: a
  playlist that disappears is now simply no longer followed.
- **A channel's records remember it** (`channel` in the record). That is what lets a
  video that vanished from a followed channel be told apart from one you stopped
  following.
- **URLs are rewritten to `https://www.youtube.com/watch?v=<id>`** before ArchiveBox
  sees them. Shared links carry `?si=` tracking, and one in the live backup carried
  `&list=RD…&start_radio=1`; ArchiveBox runs yt-dlp with `--yes-playlist`, so that link
  as stored would have archived an endless radio mix.
- **A second tag is set through Django, not `add --tag`.** With `ONLY_NEW`, `add` skips
  a URL that already has a snapshot before tagging it, so a video in both playlists
  would never get its second tag. `grayjay.abx.py` adds missing tags on every run, so
  removing a playlist tag in the ArchiveBox UI is undone the next morning while the
  video is still in that playlist.
- **ArchiveBox's status is not trusted, in either direction; the files decide.** The
  ytdlp plugin reports success for any media file, including a `.fNNN.` stream left when
  a timeout falls between yt-dlp's separate video and audio downloads, and the first
  backfill also produced the reverse: a result marked failed, with no message, holding a
  complete hour-long merged `.webm`. A video counts as archived exactly when a merged,
  non-partial media file is present, whatever the status says. "Partial" covers more
  than `.part`: a stream with any format id (`.f251.`, `.f251-5.`, `.fhls-720p.`) and a
  merge killed partway (`.temp.webm`) both carry real media extensions. Two videos were
  counted saved that way until 2026-11-05.
- **`YTDLP_MAX_SIZE=5000m` is a preference, not a cap.** The plugin's format selector
  is `(bv*+ba/b)[filesize<=5000m]/(bv*+ba/b)`, which falls back to the best format with
  no size limit. A video over 5 GB downloads anyway, or hits the 2-hour
  `YTDLP_TIMEOUT` and is dropped.
- **Removing a video from a playlist never deletes the archived copy.**
- **If the job itself stops**, the alert comes from the daily watchdog on the `host`
  topic, not here.
